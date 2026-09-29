# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadGrader — the road's terrain effect, as a pure kernel: given a heightfield, a plan polyline
# and a SOLVED vertical alignment (Pasture3DRoadAlignment, P1), produce the graded surface and the channel
# masks. Driven by Pasture3DNodeRoad inside a brush's modifier stack; see
# PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §8.
#
# ---- WHY THIS IS STATIC, AND TAKES ARRAYS RATHER THAN NODES ----
#
# Nothing here touches a Node, a Terrain, a Path3D or an editor. It takes numbers and returns numbers, so
# it can be gated on analytic fixtures where the right answer is known in closed form — a straight road on
# a tilted plane has an exact cut depth at every cell, and that is the only kind of fixture that can tell
# a working grader from one that merely produces plausible-looking earthworks. The brush resolves the
# hierarchy (§5.3) and the RoadType widths, and hands the results in as plain per-sample arrays.
#
# ---- DISTANCE IS ANALYTIC, NOT JUMP-FLOODED (§8) ----
#
# The distance transform uses JFA because an exact scan is sequential and could not go to the GPU, so CPU
# and GPU would disagree across the 256² threshold. That reasoning does NOT apply to a set of line
# segments: point-to-segment distance is closed form, embarrassingly parallel, and bit-comparable on both
# backends by construction. It also yields `s` — the arc length at the closest point — which JFA cannot,
# and without which there is no way to ask the alignment how high the road is here. The whole grader
# hangs off that one query.
@tool
class_name Pasture3DRoadGrader
extends RefCounted

## Cells whose height moved by less than this are treated as untouched, so the cut and fill masks mark
## real earthworks rather than float noise at the batter's feather edge.
const EARTHWORK_EPSILON: float = 0.001


## Cumulative arc length at each plan point, metres. Element 0 is 0 and the last is the total length.
static func cumulative_length(p_plan: PackedVector2Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := p_plan.size()
	out.resize(n)
	if n == 0:
		return out
	out[0] = 0.0
	for i in range(1, n):
		out[i] = out[i - 1] + p_plan[i].distance_to(p_plan[i - 1])
	return out


## The road surface height at signed across-distance `p_u`, given the centreline height there.
##
## THE PROFILE, DEFINED ONCE. The mesher (P5b) draws the ribbon this describes and the grader carves the
## ground it sits on, and if the two ever disagreed by a millimetre the road would z-fight along its whole
## length — a defect that looks like a rendering bug and is arithmetic. So neither owns it.
##
## `p_bank` is superelevation as a rise/run ratio signed like curvature (positive across-distance is the
## driver's RIGHT), and `p_crown` sheds water from the centreline to both edges.
## `p_crown_mode`: 0 = PARABOLIC (smooth quadratic, zero centerline slope),
##                 1 = ONE_WAY_CROSSFALL (constant tilt for motorways/ovals),
##                 2 = CIRCULAR_ARC (exact circular geometry),
##                 3 = V_ROOF (legacy knife-edge peak).
## `p_max_bank`: when > 0, dynamic superelevation runoff attenuates the crown to 0 in banked turns.
static func surface_height(p_centre: float, p_bank: float, p_crown: float, p_u: float,
		p_half_width: float = 4.0, p_crown_mode: int = 0, p_max_bank: float = 0.0) -> float:
	var wh: float = p_half_width if p_half_width > 0.01 else 4.0
	var abs_u: float = absf(p_u)
	var z_crown := 0.0
	match p_crown_mode:
		1: # ONE_WAY_CROSSFALL
			z_crown = -p_crown * p_u
		2: # CIRCULAR_ARC
			var hc := p_crown * wh
			if hc > 1e-6:
				var r := (wh * wh + hc * hc) / (2.0 * hc)
				if abs_u <= wh and r > abs_u:
					z_crown = sqrt(r * r - p_u * p_u) - r
				else:
					var slope_edge := -wh / sqrt(maxf(r * r - wh * wh, 1e-6))
					z_crown = -hc + slope_edge * (abs_u - wh)
		3: # V_ROOF (legacy)
			z_crown = -p_crown * abs_u
		_: # 0: PARABOLIC
			var hc := p_crown * wh
			if abs_u <= wh:
				var ratio := p_u / wh
				z_crown = -hc * ratio * ratio
			else:
				z_crown = -hc - (2.0 * p_crown) * (abs_u - wh)

	var eta := 1.0
	if p_max_bank > 1e-5:
		eta = clampf(1.0 - absf(p_bank) / p_max_bank, 0.0, 1.0)

	return p_centre + p_bank * p_u + eta * z_crown


## The ground height `p_beyond` metres past the edge of formation, for a batter leaving the edge at
## `p_z_edge` and meeting ground `p_ground`. THE BATTER, DEFINED ONCE -- the native `road_batter_height`
## is this, line for line, and the corridor grader, the junction footprint batter and the wall mesh all
## read one or the other.
##
##   p_edge_slope   outward slope of the finished surface at the edge (`edge_slope`); read only when
##                  `p_hinge` > 0
##   p_toe          metres either side of the toe the batter is filleted into the ground; 0 = crease
##   p_hinge        metres over which the edge rolls over into the batter (the curve spans 2x this)
##
## Retaining walls are not here: `walled_height` wraps this with a wall plan record.
##
## ---- WHY THE HINGE STARTS AT THE EDGE ----
##
## A vertical curve normally straddles the grade change. Straddling it here would lower the shoulder,
## which the ribbon lies on, and the ribbon would float over a dip along its own edge. So the curve leaves
## the edge at the surface's own cross-slope and arrives at the batter slope `2 * p_hinge` further out; the
## batter beyond it runs `(g1 - g2) * p_hinge` proud of the unrounded one, moving the toe out by about
## `p_hinge`.
##
## ---- WHY THE TOE'S WIDTH IS CAPPED BY THE RUN ----
##
## The smooth max lifts the result by up to k/4 wherever the batter and the ground are within k of each
## other. Right at the edge, on ground just below the road, that is a lip standing proud of the formation.
## Capping k by the run so far makes the blend vanish at the edge, where the batter starts.
static func batter_height(p_ground: float, p_z_edge: float, p_edge_slope: float, p_beyond: float,
		p_cut_batter: float, p_fill_batter: float, p_toe: float = 0.0, p_hinge: float = 0.0) -> float:
	var fill := p_z_edge > p_ground
	var batter := p_fill_batter if fill else p_cut_batter
	var g2 := -batter if fill else batter
	var x := maxf(p_beyond, 0.0)
	var line := batter_line(p_z_edge, p_edge_slope, g2, x, p_hinge)
	var k := batter * minf(maxf(p_toe, 0.0), x)
	if k > 1e-9:
		var hk := maxf(k - absf(line - p_ground), 0.0) / k
		var bump := hk * hk * k * 0.25
		return (maxf(p_ground, line) + bump) if fill else (minf(p_ground, line) - bump)
	return maxf(p_ground, line) if fill else minf(p_ground, line)


## The batter's own surface `p_x` metres past the edge, before it meets the ground: the straight batter at
## slope `p_g2` (negative falls), rolled over from the edge slope `p_g1` across `2 * p_hinge` metres.
static func batter_line(p_z_edge: float, p_g1: float, p_g2: float, p_x: float, p_hinge: float) -> float:
	var r := maxf(p_hinge, 0.0)
	if r <= 1e-6:
		return p_z_edge + p_g2 * p_x
	if p_x < 2.0 * r:
		return p_z_edge + p_g1 * p_x + (p_g2 - p_g1) * p_x * p_x / (4.0 * r)
	return p_z_edge + (p_g1 + p_g2) * r + p_g2 * (p_x - 2.0 * r)


## Metres past the edge at which a batter has climbed (`p_g2` > 0) or fallen (`p_g2` < 0) `p_height` from
## the edge: where a BATTER_TOP retaining wall of that height stands. INF when it never does.
static func wall_run(p_height: float, p_g1: float, p_g2: float, p_hinge: float) -> float:
	if p_height <= 0.0 or absf(p_g2) < 1e-6:
		return INF
	var sgn := signf(p_g2)
	var lo := 0.0
	var hi := 2.0 * maxf(p_hinge, 0.0) + p_height / absf(p_g2) + 1.0
	for _i in 24:
		if sgn * (batter_line(0.0, p_g1, p_g2, hi, p_hinge)) >= p_height:
			break
		hi *= 2.0
	for _i in 48:
		var mid := 0.5 * (lo + hi)
		if sgn * batter_line(0.0, p_g1, p_g2, mid, p_hinge) >= p_height:
			hi = mid
		else:
			lo = mid
	return hi


## Outward slope of the finished road surface at the formation edge `p_edge_d` on side `p_side`, taken
## from one short step inside it. Native `road_edge_slope`, line for line.
static func edge_slope(p_z_ref: float, p_bank: float, p_crown: float, p_edge_d: float, p_side: float,
		p_half: float, p_crown_mode: int = 0, p_max_bank: float = 0.0) -> float:
	var step := minf(0.05, maxf(p_edge_d, 1e-3) * 0.5)
	var side := p_side if p_side != 0.0 else 1.0
	var z_edge := surface_height(p_z_ref, p_bank, p_crown, p_edge_d * side, p_half, p_crown_mode, p_max_bank)
	var z_in := surface_height(p_z_ref, p_bank, p_crown, (p_edge_d - step) * side, p_half, p_crown_mode,
			p_max_bank)
	return (z_edge - z_in) / step


## ---- RETAINING WALLS (PASTURE3D_ROAD_WALL_SPEC.md) ----------------------------------------------------

## Stride of one record in a wall plan: `[mode, kind, W, alpha, o, x_s, beyond]`. Sample i, side k (0 the
## left, side -1; 1 the right, +1) starts at `(i * 2 + k) * WALL_STRIDE`.
const WALL_STRIDE: int = 7
const WALL_NONE: int = 0
const WALL_ROAD_SIDE: int = 1
const WALL_BATTER_TOP: int = 2
## A ROAD_SIDE wall that would hold back less than this, metres, is not built.
const WALL_MIN_HELD: float = 0.05


## The wall record at arc length `p_s` on side `p_side`, or an empty array where the plan has none.
## Interpolated LINEARLY between the two bracketing samples when both carry the same mode and kind, so a
## tapering wall has no stair along the road; the nearest record otherwise, which is where a square end
## falls. Native `road_wall_record_at`, line for line.
static func wall_record_at(p_plan: PackedFloat32Array, p_s: float, p_ds: float, p_s0: float,
		p_side: float) -> PackedFloat32Array:
	var n := p_plan.size() / (2 * WALL_STRIDE)
	if n <= 0:
		return PackedFloat32Array()
	var k := 0 if p_side < 0.0 else 1
	var i0 := 0
	var f := 0.0
	if n > 1:
		var t := (p_s - p_s0) / maxf(p_ds, 1e-6)
		i0 = clampi(int(floor(t)), 0, n - 2)
		f = clampf(t - float(i0), 0.0, 1.0)
	var a := (i0 * 2 + k) * WALL_STRIDE
	var b := (mini(i0 + 1, n - 1) * 2 + k) * WALL_STRIDE
	var out := PackedFloat32Array()
	out.resize(WALL_STRIDE)
	if p_plan[a] == p_plan[b] and p_plan[a + 1] == p_plan[b + 1]:
		out[0] = p_plan[a]
		out[1] = p_plan[a + 1]
		for j in range(2, WALL_STRIDE):
			out[j] = lerpf(p_plan[a + j], p_plan[b + j], f)
	else:
		var c := a if f < 0.5 else b
		for j in WALL_STRIDE:
			out[j] = p_plan[c + j]
	return out


## How far past the edge of formation a walled batter can reach, for `p_rise` metres between road and
## ground, over the two samples bracketing `p_s` on both sides. 0 where neither has a ROAD_SIDE wall. The
## walled batter is `x_s` of flat ground and then a batter at `beyond`, which can reach further than the
## plain one when `beyond` is the shallower. Native `road_wall_reach`, line for line.
static func wall_reach(p_plan: PackedFloat32Array, p_s: float, p_ds: float, p_s0: float,
		p_rise: float) -> float:
	var n := p_plan.size() / (2 * WALL_STRIDE)
	if n <= 0:
		return 0.0
	var i0 := clampi(int(floor((p_s - p_s0) / maxf(p_ds, 1e-6))), 0, n - 1)
	var best := 0.0
	for i in [i0, mini(i0 + 1, n - 1)]:
		for k in 2:
			var a: int = (i * 2 + k) * WALL_STRIDE
			if int(p_plan[a]) == WALL_ROAD_SIDE:
				best = maxf(best, p_plan[a + 5] + p_rise / maxf(p_plan[a + 6], 0.01))
	return best


## The ground `p_beyond` metres past the edge of formation with the wall record `p_rec` (from
## `wall_record_at`) standing there. `batter_height` exactly where there is no wall, or where the cell is
## not the kind the wall was planned for. Native `road_wall_height`, line for line. See spec §5.
static func walled_height(p_ground: float, p_z_edge: float, p_edge_slope: float, p_beyond: float,
		p_cut_batter: float, p_fill_batter: float, p_toe: float, p_hinge: float,
		p_rec: PackedFloat32Array) -> float:
	var plain := batter_height(p_ground, p_z_edge, p_edge_slope, p_beyond, p_cut_batter, p_fill_batter,
			p_toe, p_hinge)
	if p_rec.size() < WALL_STRIDE:
		return plain
	var mode := int(p_rec[0])
	var w: float = p_rec[2]
	if mode == WALL_NONE or w <= 0.0:
		return plain
	var fill := p_z_edge > p_ground
	# A cut wall's record on a cell the road fills (or the reverse): the plain batter, not a wall.
	if fill == (p_rec[1] > 0.0):
		return plain
	var x := maxf(p_beyond, 0.0)
	var batter := p_fill_batter if fill else p_cut_batter
	var g2 := -batter if fill else batter
	var l_plain := batter_line(p_z_edge, p_edge_slope, g2, x, p_hinge)
	if mode == WALL_BATTER_TOP:
		# The batter up to the wall's height, and the ground left standing past it.
		if ((p_z_edge - l_plain) if fill else (l_plain - p_z_edge)) > w:
			return p_ground
		return plain
	# ROAD_SIDE. Flat at the edge's height out to the step at x_s, where the wall holds the ground `w`
	# above (cut) or below (fill); past it a batter at `beyond`. `alpha` blends from the plain batter,
	# which is how a run's end tapers into the earthwork it replaces.
	var alpha := clampf(p_rec[3], 0.0, 1.0)
	var xs: float = p_rec[5]
	var beyond := maxf(p_rec[6], 0.01)
	var sgn := -1.0 if fill else 1.0
	var l_wall := p_z_edge if x < xs else p_z_edge + sgn * (w + beyond * (x - xs))
	var line := lerpf(l_plain, l_wall, alpha)
	# The toe fillet, as in `batter_height`, but measured from the step rather than the edge: behind a
	# full wall the ground is flat up to x_s, and a fillet reaching back into it would lift the ditch.
	var slope := lerpf(batter, beyond, alpha)
	var k := slope * minf(maxf(p_toe, 0.0), maxf(x - alpha * xs, 0.0))
	if k > 1e-9:
		var hk := maxf(k - absf(line - p_ground), 0.0) / k
		var bump := hk * hk * k * 0.25
		return (maxf(p_ground, line) + bump) if fill else (minf(p_ground, line) - bump)
	return maxf(p_ground, line) if fill else minf(p_ground, line)


## The wall plan for a solved road (spec §4): one record per alignment sample and side, stored on the
## alignment and read by the grader and the wall mesh alike, so neither can drift from the other.
##
##   p_plan, p_cum  the plan polyline and its arc lengths
##   p_alignment    the solved alignment
##   p_prof         a `grading_profile`: half, shoulder, suppress, skip, walls, cut_wall_idx,
##                  fill_wall_idx, crown, cut_batter, fill_batter, hinge_rounding
##   p_opts         crown_mode, max_bank
##   p_sampler      Callable(PackedVector2Array) -> PackedFloat32Array: the ground at each point, NaN where
##                  there is none. Called once per lateral step for every sample at once.
##   p_step         lateral march step, metres
##
## Returns an empty array when no sample has a wall, which every consumer reads as "no walls".
static func build_wall_plan(p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_alignment: Pasture3DRoadAlignment, p_prof: Dictionary, p_opts: Dictionary,
		p_sampler: Callable, p_step: float) -> PackedFloat32Array:
	var walls: Array = p_prof.get("walls", [])
	if walls.is_empty() or p_alignment == null or p_alignment.count() < 2 or p_plan.size() < 2:
		return PackedFloat32Array()
	var n := p_alignment.count()
	var ds := maxf(p_alignment.ds, 1e-3)
	var total: float = p_cum[p_cum.size() - 1]
	var half: PackedFloat32Array = p_prof.get("half", PackedFloat32Array())
	var shoulder: PackedFloat32Array = p_prof.get("shoulder", PackedFloat32Array())
	var suppress: PackedByteArray = p_prof.get("suppress", PackedByteArray())
	var skip: PackedByteArray = p_prof.get("skip", PackedByteArray())
	var cut_idx: PackedInt32Array = p_prof.get("cut_wall_idx", PackedInt32Array())
	var fill_idx: PackedInt32Array = p_prof.get("fill_wall_idx", PackedInt32Array())
	var crown := float(p_prof.get("crown", 0.05))
	var cut_b := maxf(float(p_prof.get("cut_batter", 1.0)), 0.01)
	var fill_b := maxf(float(p_prof.get("fill_batter", 0.6)), 0.01)
	var hinge := maxf(float(p_prof.get("hinge_rounding", 0.0)), 0.0)
	var crown_mode := int(p_opts.get("crown_mode", 0))
	var max_bank := float(p_opts.get("max_bank", 0.0))
	var step := maxf(p_step, 0.1)

	# ---- 1. THE ENTRIES: every sample and side that could carry a wall ----
	var e_i := PackedInt32Array()
	var e_side := PackedFloat32Array()
	var e_edge := PackedFloat32Array()
	var e_zedge := PackedFloat32Array()
	var e_g1 := PackedFloat32Array()
	var e_c := PackedVector2Array()
	var e_across := PackedVector2Array()
	for i in n:
		if (i < suppress.size() and suppress[i] != 0) or (i < skip.size() and skip[i] != 0):
			continue
		if _at_i(cut_idx, i) < 0 and _at_i(fill_idx, i) < 0:
			continue
		var s := p_alignment.s0 + float(i) * ds
		if s > total + 1e-3:
			continue
		var hw := _at(half, i, 3.5)
		var edge_d := hw + _at(shoulder, i, 0.5)
		var z_ref := p_alignment.height_at(s)
		var bank: float = p_alignment.bank[i] if i < p_alignment.bank.size() else 0.0
		var c := plan_point_at(p_plan, p_cum, minf(s, total))
		var t2 := _segment_dir_at(p_plan, p_cum, minf(s, total), false)
		for side in [-1.0, 1.0]:
			e_i.append(i)
			e_side.append(side)
			e_edge.append(edge_d)
			e_zedge.append(surface_height(z_ref, bank, crown, edge_d * side, hw, crown_mode, max_bank))
			e_g1.append(edge_slope(z_ref, bank, crown, edge_d, side, hw, crown_mode, max_bank) \
					if hinge > 0.0 else 0.0)
			e_c.append(c)
			e_across.append(Vector2(-t2.y, t2.x) * side)
	var m := e_i.size()
	if m == 0:
		return PackedFloat32Array()

	# ---- 2. THE MARCH: the plain batter's catch height at every entry, batched per lateral step ----
	var e_kind := PackedFloat32Array() # +1 cut, -1 fill, 0 no wall for its kind
	var e_widx := PackedInt32Array()
	var e_hc := PackedFloat32Array()
	var e_prev := PackedFloat32Array() # the batter line at the previous step
	var e_pdiff := PackedFloat32Array() # kind * (ground - line) at the previous step
	var e_cap := PackedFloat32Array()
	var live := PackedByteArray()
	e_kind.resize(m); e_widx.resize(m); e_hc.resize(m); e_prev.resize(m); e_pdiff.resize(m)
	e_cap.resize(m); live.resize(m)
	e_hc.fill(0.0)
	live.fill(1)
	var min_b := minf(cut_b, fill_b)
	var cap_all := 0.0
	for w: Pasture3DRoadWall in walls:
		cap_all = maxf(cap_all, maxf(w.max_height, w.trigger_height))
		if w.beyond_batter > 0.0:
			min_b = minf(min_b, w.beyond_batter)
	var steps := clampi(int(ceil((2.0 * hinge + (cap_all + step) / min_b) / step)) + 1, 1, 2000)
	var pts := PackedVector2Array()
	pts.resize(m)
	for mm in range(1, steps + 1):
		var x := float(mm) * step
		var any := false
		for e in m:
			if live[e] != 0:
				pts[e] = e_c[e] + e_across[e] * (e_edge[e] + x)
				any = true
		if not any:
			break
		var g: PackedFloat32Array = p_sampler.call(pts)
		for e in m:
			if live[e] == 0:
				continue
			var ge: float = g[e] if e < g.size() else NAN
			var z_edge: float = e_zedge[e]
			if mm == 1:
				# The kind is set by the ground one step past the edge: above the edge is a cut.
				if not is_finite(ge):
					live[e] = 0
					continue
				var kind := 1.0 if ge > z_edge else -1.0
				var widx := _at_i(cut_idx if kind > 0.0 else fill_idx, e_i[e])
				e_kind[e] = kind
				e_widx[e] = widx
				if widx < 0:
					live[e] = 0
					continue
				var wr: Pasture3DRoadWall = walls[widx]
				e_cap[e] = maxf(wr.max_height, wr.trigger_height) + step
				e_prev[e] = z_edge
				e_pdiff[e] = kind * (ge - z_edge)
			var kd: float = e_kind[e]
			var line := batter_line(z_edge, e_g1[e], kd * (cut_b if kd > 0.0 else fill_b), x, hinge)
			if not is_finite(ge):
				e_hc[e] = kd * (e_prev[e] - z_edge)
				live[e] = 0
				continue
			var diff := kd * (ge - line)
			if diff <= 0.0:
				# Caught between the last step and this one: the crossing, linearly.
				var pd: float = e_pdiff[e]
				var tt := clampf(pd / maxf(pd - diff, 1e-9), 0.0, 1.0)
				e_hc[e] = kd * (lerpf(e_prev[e], line, tt) - z_edge)
				live[e] = 0
				continue
			if kd * (line - z_edge) >= e_cap[e]:
				e_hc[e] = kd * (line - z_edge) # still climbing past anything a wall could use
				live[e] = 0
				continue
			e_prev[e] = line
			e_pdiff[e] = diff

	# ---- 3. NEED, per sample and side ----
	#
	# The catch height decides WHETHER a wall stands (the batter it replaces would be taller than the
	# trigger), but not how tall. A ROAD_SIDE wall retains the ground at its own back face, x_s past the
	# edge, and nothing more: sizing it by the catch height put the top of a wall on a 1:2 hillside 1.7 m
	# above the ground behind it. So the need is read again, at x_s, in one more batched call.
	var need := PackedFloat32Array()
	var key := PackedInt32Array() # widx * 2 + (kind > 0), or -1
	need.resize(n * 2)
	key.resize(n * 2)
	need.fill(0.0)
	key.fill(-1)
	var back_e := PackedInt32Array()
	var back_pts := PackedVector2Array()
	for e in m:
		var widx := e_widx[e]
		if e_kind[e] == 0.0 or widx < 0:
			continue
		var wr: Pasture3DRoadWall = walls[widx]
		if e_hc[e] <= wr.trigger_height:
			continue
		var slot := e_i[e] * 2 + (0 if e_side[e] < 0.0 else 1)
		if wr.placement == Pasture3DRoadWall.Placement.BATTER_TOP:
			need[slot] = wr.trigger_height
			key[slot] = widx * 2 + (1 if e_kind[e] > 0.0 else 0)
			continue
		back_e.append(e)
		back_pts.append(e_c[e] + e_across[e] * (e_edge[e] + wr.offset + wr.thickness))
	if not back_e.is_empty():
		var gb: PackedFloat32Array = p_sampler.call(back_pts)
		for q in back_e.size():
			var e := back_e[q]
			var gq: float = gb[q] if q < gb.size() else NAN
			var held := e_kind[e] * (gq - e_zedge[e])
			if not is_finite(held) or held <= WALL_MIN_HELD:
				continue
			var wr: Pasture3DRoadWall = walls[e_widx[e]]
			var slot := e_i[e] * 2 + (0 if e_side[e] < 0.0 else 1)
			need[slot] = minf(wr.max_height, held)
			key[slot] = e_widx[e] * 2 + (1 if e_kind[e] > 0.0 else 0)

	var out := PackedFloat32Array()
	out.resize(n * 2 * WALL_STRIDE)
	out.fill(0.0)
	var any_wall := false
	for k in 2:
		# ---- 4. RUNS: bridge short gaps, then drop short runs ----
		var runs: Array = [] # [start, end, key]
		var i := 0
		while i < n:
			var ky := key[i * 2 + k]
			if ky < 0:
				i += 1
				continue
			var j := i
			while j + 1 < n and key[(j + 1) * 2 + k] == ky:
				j += 1
			runs.append([i, j, ky])
			i = j + 1
		var merged: Array = []
		for r in runs:
			if not merged.is_empty():
				var last: Array = merged[merged.size() - 1]
				var wr: Pasture3DRoadWall = walls[int(r[2]) / 2]
				var gap := int(r[0]) - int(last[1]) - 1
				if int(last[2]) == int(r[2]) and float(gap) * ds < wr.gap_bridge \
						and not _any_blocked(suppress, skip, int(last[1]) + 1, int(r[0]) - 1):
					var a_need := need[int(last[1]) * 2 + k]
					var b_need := need[int(r[0]) * 2 + k]
					for g in range(int(last[1]) + 1, int(r[0])):
						var f := float(g - int(last[1])) / float(gap + 1)
						need[g * 2 + k] = lerpf(a_need, b_need, f)
						key[g * 2 + k] = int(r[2])
					last[1] = r[1]
					continue
			merged.append(r.duplicate())
		for r in merged:
			var r0 := int(r[0])
			var r1 := int(r[1])
			var widx := int(r[2]) / 2
			var cut := int(r[2]) % 2 == 1
			var wr: Pasture3DRoadWall = walls[widx]
			if float(r1 - r0 + 1) * ds < wr.min_length:
				continue
			# ---- 5. THE TOP ----
			var tops := PackedFloat32Array()
			tops.resize(r1 - r0 + 1)
			if wr.top_mode == Pasture3DRoadWall.TopMode.FOLLOW_ROAD:
				var mx := 0.0
				for g in range(r0, r1 + 1):
					mx = maxf(mx, need[g * 2 + k])
				tops.fill(mx)
			elif wr.top_mode == Pasture3DRoadWall.TopMode.STEPPED:
				var blk := maxi(int(round(wr.step_length / ds)), 1)
				var b0 := r0
				while b0 <= r1:
					var b1 := mini(b0 + blk - 1, r1)
					var mx := 0.0
					for g in range(b0, b1 + 1):
						mx = maxf(mx, need[g * 2 + k])
					var q := ceilf(mx / wr.step_height - 1e-6) * wr.step_height
					for g in range(b0, b1 + 1):
						tops[g - r0] = q
					b0 = b1 + 1
			else:
				var win := int(round(wr.top_smoothing / (2.0 * ds)))
				for g in range(r0, r1 + 1):
					var acc := 0.0
					var cnt := 0
					for h in range(maxi(g - win, r0), mini(g + win, r1) + 1):
						acc += need[h * 2 + k]
						cnt += 1
					tops[g - r0] = acc / float(maxi(cnt, 1))
			var beyond := wr.beyond_batter if wr.beyond_batter > 0.0 else (cut_b if cut else fill_b)
			var mode := WALL_ROAD_SIDE if wr.placement == Pasture3DRoadWall.Placement.ROAD_SIDE \
					else WALL_BATTER_TOP
			for g in range(r0, r1 + 1):
				# ---- 6. THE ENDS ----
				var alpha := 1.0
				if wr.end_treatment == Pasture3DRoadWall.EndTreatment.TAPER:
					var d := float(mini(g - r0, r1 - g)) * ds
					var u := clampf(d / wr.end_taper_length, 0.0, 1.0)
					alpha = u * u * (3.0 - 2.0 * u)
				var a := (g * 2 + k) * WALL_STRIDE
				out[a] = mode
				out[a + 1] = 1.0 if cut else -1.0
				# BATTER_TOP is the old cap: the wall stands where the batter has climbed the trigger.
				out[a + 2] = wr.trigger_height if mode == WALL_BATTER_TOP else minf(tops[g - r0], wr.max_height)
				out[a + 3] = alpha
				out[a + 4] = wr.offset
				out[a + 5] = wr.offset + wr.thickness
				out[a + 6] = beyond
				any_wall = true
	return out if any_wall else PackedFloat32Array()


static func _at_i(p_arr: PackedInt32Array, p_i: int) -> int:
	if p_arr.is_empty():
		return -1
	return p_arr[clampi(p_i, 0, p_arr.size() - 1)]


static func _any_blocked(p_suppress: PackedByteArray, p_skip: PackedByteArray, p_a: int, p_b: int) -> bool:
	for i in range(p_a, p_b + 1):
		if (i < p_suppress.size() and p_suppress[i] != 0) or (i < p_skip.size() and p_skip[i] != 0):
			return true
	return false


## A turn sharper than this at a spline point, in radians, is a kink to be rounded. Well under what anyone
## draws on purpose, and well over the rounding noise of mirrored handles, which is zero.
const KINK_MIN_ANGLE: float = 0.01

## Most of the arc length to a neighbouring kink (or the end of an open road) one fillet may use, so two
## close kinks each get room and neither fillet swallows the other.
const FILLET_SHARE: float = 0.45

## Degrees of turn per sample along a fillet.
const FILLET_STEP_DEG: float = 4.0


## Round every kink of a plan polyline into an arc of radius `p_radius`, WITHOUT editing the spline it came
## from. The one geometry every consumer of the plan reads (grading, ribbon, paint, junctions, pace notes),
## so they all flow through the corner together; rounding any one of them alone would leave the ribbon
## hanging off the graded ground by the corner's miter.
##
##   p_pts      the plan, world XZ, as tessellated
##   p_kinks    plan vertex indices to round, with the turn angle there in `p_angles` (radians). For a
##              closed plan, a kink at the closure is index 0 (the last vertex repeats the first).
##   p_ctrl     plan vertex index of every spline control point, in global point order
##   p_closed   the plan is a closed loop
##
## Returns `{plan, cum, ctrl_s}`: the new polyline, its arc lengths, and the arc length at which every
## control point now sits. A rounded control point sits at its arc's midpoint, and on a closed plan whose
## closure was rounded that midpoint is s = 0, so arc length keeps starting where the first point is.
##
## ---- THE TANGENT LENGTH IS CAPPED, NOT THE RADIUS ----
##
## `T = R tan(theta/2)` back and forward from the kink. Two kinks closer than that would overlap their
## arcs, and a hairpin (theta near pi) would reach back kilometres. So `T` is capped at FILLET_SHARE of the
## distance to the neighbouring kink or end, and a capped corner is simply rounded tighter than asked --
## the kink goes either way, which is the point.
static func fillet_plan(p_pts: PackedVector2Array, p_kinks: PackedInt32Array, p_angles: PackedFloat32Array,
		p_ctrl: PackedInt32Array, p_radius: float, p_closed: bool) -> Dictionary:
	var cum := cumulative_length(p_pts)
	var n := p_pts.size()
	var ctrl_s := PackedFloat32Array()
	for v in p_ctrl:
		ctrl_s.append(cum[clampi(v, 0, n - 1)] if n > 0 else 0.0)
	if p_radius <= 0.0 or n < 3 or p_kinks.is_empty():
		return {"plan": p_pts, "cum": cum, "ctrl_s": ctrl_s}
	var total: float = cum[n - 1]
	# Kinks in arc-length order.
	var order: Array = []
	for i in p_kinks.size():
		var v: int = p_kinks[i]
		if v < 0 or v >= n:
			continue
		if not p_closed and (v == 0 or v == n - 1):
			continue
		if p_closed and v == n - 1:
			v = 0
		var th: float = p_angles[i] if i < p_angles.size() else 0.0
		if th < KINK_MIN_ANGLE:
			continue
		order.append([cum[v], v, th])
	if order.is_empty():
		return {"plan": p_pts, "cum": cum, "ctrl_s": ctrl_s}
	order.sort_custom(func(a, b): return a[0] < b[0])
	# Kinks at one arc length are one corner (a spline join, a doubled point): keep the sharpest. Left as
	# two they would leave each other no room, and neither would be rounded.
	var merged: Array = []
	for o in order:
		if not merged.is_empty() and float(o[0]) - float(merged[merged.size() - 1][0]) < 1e-4:
			if float(o[2]) > float(merged[merged.size() - 1][2]):
				merged[merged.size() - 1] = o
			continue
		merged.append(o)
	order = merged
	var k := order.size()
	var corners: Array = []
	for i in k:
		var s: float = order[i][0]
		var th: float = order[i][2]
		var room_back: float
		var room_fwd: float
		if p_closed:
			var s_prev: float = order[(i - 1 + k) % k][0]
			var s_next: float = order[(i + 1) % k][0]
			room_back = fposmod(s - s_prev, total) if k > 1 else total * 0.5
			room_fwd = fposmod(s_next - s, total) if k > 1 else total * 0.5
			# An arc may not cross the seam unless it is the seam's own: the walk below splices one
			# wrapping arc, the closure's, and no other.
			if int(order[i][1]) != 0:
				room_back = minf(room_back, s / FILLET_SHARE)
				room_fwd = minf(room_fwd, (total - s) / FILLET_SHARE)
		else:
			room_back = s - (float(order[i - 1][0]) if i > 0 else 0.0)
			room_fwd = (float(order[i + 1][0]) if i < k - 1 else total) - s
		var t_len := p_radius * tan(minf(th, PI - 0.02) * 0.5)
		t_len = minf(t_len, FILLET_SHARE * minf(room_back, room_fwd))
		if t_len <= 1e-3:
			continue
		corners.append({"s": s, "v": int(order[i][1]), "t": t_len})
	if corners.is_empty():
		return {"plan": p_pts, "cum": cum, "ctrl_s": ctrl_s}

	# Each corner's arc, as points from A (s - t) to B (s + t) inclusive.
	for c in corners:
		var sa: float = float(c["s"]) - float(c["t"])
		var sb: float = float(c["s"]) + float(c["t"])
		if p_closed:
			sa = fposmod(sa, total)
			sb = fposmod(sb, total)
		var a := plan_point_at(p_pts, cum, sa)
		var b := plan_point_at(p_pts, cum, sb)
		var ta := _segment_dir_at(p_pts, cum, sa, true)
		var tb := _segment_dir_at(p_pts, cum, sb, false)
		c["arc"] = _fillet_arc(a, ta, b, tb)

	var out := PackedVector2Array()
	var old_to_new := PackedInt32Array()
	old_to_new.resize(n)
	old_to_new.fill(-1)
	var mids: Dictionary = {} # corner vertex -> new index of its arc midpoint
	var wrap: Dictionary = {}
	var walk: Array = corners
	var s_lo := -1.0
	var s_hi := total + 1.0
	if p_closed and int(corners[0]["v"]) == 0:
		# The closure itself is rounded: walk the rest strictly between its two tangent points, and splice
		# its arc around the seam, starting from the arc's midpoint so s = 0 stays at the first point.
		wrap = corners[0]
		walk = corners.slice(1)
		s_lo = float(wrap["t"])
		s_hi = total - float(wrap["t"])
	var wrap_arc: PackedVector2Array = wrap.get("arc", PackedVector2Array())
	var wrap_mid := wrap_arc.size() / 2
	if not wrap.is_empty():
		for j in range(wrap_mid, wrap_arc.size()):
			_append_point(out, wrap_arc[j])
		mids[0] = 0
	var ci := 0
	for v in n:
		var s: float = cum[v]
		if s <= s_lo or s >= s_hi:
			continue
		while ci < walk.size() and float(walk[ci]["s"]) + float(walk[ci]["t"]) <= s:
			_splice_arc(out, walk[ci], mids)
			ci += 1
		if ci < walk.size() and s > float(walk[ci]["s"]) - float(walk[ci]["t"]):
			continue # inside the next corner's arc
		_append_point(out, p_pts[v])
		old_to_new[v] = out.size() - 1
	while ci < walk.size():
		_splice_arc(out, walk[ci], mids)
		ci += 1
	if not wrap.is_empty():
		for j in range(0, wrap_mid + 1):
			_append_point(out, wrap_arc[j])
		out[out.size() - 1] = out[0]
	var new_cum := cumulative_length(out)
	for i in p_ctrl.size():
		var v: int = clampi(p_ctrl[i], 0, n - 1)
		if p_closed and v == n - 1:
			v = 0
		if mids.has(v):
			ctrl_s[i] = new_cum[int(mids[v])]
		elif old_to_new[v] >= 0:
			ctrl_s[i] = new_cum[old_to_new[v]]
		else:
			# A control point swallowed by a neighbouring corner's arc: where that arc passes nearest it.
			ctrl_s[i] = float(nearest_on_plan(out, new_cum, p_pts[v])[1])
	return {"plan": out, "cum": new_cum, "ctrl_s": ctrl_s}


static func _append_point(r_out: PackedVector2Array, p: Vector2) -> void:
	if r_out.is_empty() or r_out[r_out.size() - 1].distance_squared_to(p) > 1e-10:
		r_out.append(p)


static func _splice_arc(r_out: PackedVector2Array, p_corner: Dictionary, r_mids: Dictionary) -> void:
	var arc: PackedVector2Array = p_corner["arc"]
	var mid := arc.size() / 2
	for j in arc.size():
		_append_point(r_out, arc[j])
		if j == mid:
			r_mids[int(p_corner["v"])] = r_out.size() - 1


## Direction of the plan segment containing `p_s`. `p_before` takes the segment ENDING there when `p_s`
## falls exactly on a vertex, so a tangent point on a vertex reads the side the arc joins from. Zero-length
## segments (two splines meeting at one point) are stepped over.
static func _segment_dir_at(p_pts: PackedVector2Array, p_cum: PackedFloat32Array, p_s: float,
		p_before: bool) -> Vector2:
	var n := p_pts.size()
	var i := 0
	while i < n - 2 and (p_cum[i + 1] < p_s or (not p_before and p_cum[i + 1] <= p_s)):
		i += 1
	var j := i
	if p_before:
		while j > 0 and p_pts[j].distance_squared_to(p_pts[j + 1]) < 1e-10:
			j -= 1
	else:
		while j < n - 2 and p_pts[j].distance_squared_to(p_pts[j + 1]) < 1e-10:
			j += 1
	var d := p_pts[j + 1] - p_pts[j]
	return d.normalized() if d.length_squared() > 1e-12 else Vector2.RIGHT


## A cubic from `p_a` leaving along `p_ta` to `p_b` arriving along `p_tb`, with the handle length that makes
## it a circular arc when the two tangents are symmetric about the chord.
static func _fillet_arc(p_a: Vector2, p_ta: Vector2, p_b: Vector2, p_tb: Vector2) -> PackedVector2Array:
	var chord := p_a.distance_to(p_b)
	var phi := acos(clampf(p_ta.dot(p_tb), -1.0, 1.0))
	var h := chord / 3.0
	if phi > 1e-4:
		var r := chord / (2.0 * sin(phi * 0.5))
		h = 4.0 / 3.0 * tan(phi * 0.25) * r
	h = minf(h, chord)
	var c1 := p_a + p_ta * h
	var c2 := p_b - p_tb * h
	# EVEN, so the middle sample is u = 0.5 -- the arc's own midpoint, where the control point it rounds is
	# said to sit (and, on a closed plan, where s = 0 starts). An odd count put it half a step along.
	var m := clampi(int(ceil(rad_to_deg(phi) / FILLET_STEP_DEG)), 4, 64)
	m += m % 2
	var out := PackedVector2Array()
	for j in m + 1:
		var u := float(j) / float(m)
		var w := 1.0 - u
		out.append(p_a * (w * w * w) + c1 * (3.0 * w * w * u) + c2 * (3.0 * w * u * u) + p_b * (u * u * u))
	return out


## World XZ of the point `p_s` metres along the plan polyline. Clamped at both ends.
##
## Public because the mesher, the brush and the junction gizmo all need it, and three copies of "walk the
## cumulative lengths and lerp" is three places for an off-by-one to live.
static func plan_point_at(p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_s: float) -> Vector2:
	var n := p_plan.size()
	if n == 0:
		return Vector2.ZERO
	if n == 1 or p_cum.size() < n:
		return p_plan[0]
	var total: float = p_cum[n - 1]
	var s := clampf(p_s, 0.0, total)
	# Binary search rather than a walk: the mesher asks per vertex, and a linear scan makes meshing a road
	# quadratic in its own length.
	var lo := 0
	var hi := n - 1
	while lo + 1 < hi:
		var mid := (lo + hi) / 2
		if p_cum[mid] <= s:
			lo = mid
		else:
			hi = mid
	var span: float = p_cum[hi] - p_cum[lo]
	if span <= 1e-9:
		return p_plan[lo]
	return p_plan[lo].lerp(p_plan[hi], (s - p_cum[lo]) / span)


## Plan direction at `p_s`, normalised, pointing along INCREASING arc length.
##
## Continuous 5-point Savitzky-Golay 4th-order derivative filter with fallback to central difference
## within 2h of the ends, eliminating lateral jerk spikes and slope discontinuities.
static func plan_tangent_at(p_plan: PackedVector2Array, p_cum: PackedFloat32Array, p_s: float,
		p_h: float = 0.5, p_force_gdscript: bool = false) -> Vector2:
	if not p_force_gdscript and ClassDB.class_has_method("Pasture3DUtil", "road_plan_tangent_at"):
		return Pasture3DUtil.road_plan_tangent_at(p_plan, p_cum, p_s, p_h)
	var n := p_plan.size()
	if n < 2 or p_cum.size() < n:
		return Vector2.RIGHT
	var total: float = p_cum[n - 1]
	var h: float = maxf(p_h, 0.01)
	if p_s >= 2.0 * h and p_s <= total - 2.0 * h:
		var p_m2 := plan_point_at(p_plan, p_cum, p_s - 2.0 * h)
		var p_m1 := plan_point_at(p_plan, p_cum, p_s - h)
		var p_p1 := plan_point_at(p_plan, p_cum, p_s + h)
		var p_p2 := plan_point_at(p_plan, p_cum, p_s + 2.0 * h)
		var d := (-p_p2 + 8.0 * p_p1 - 8.0 * p_m1 + p_m2) / (12.0 * h)
		var len := d.length()
		if len > 1e-6:
			return d / len
	var a := plan_point_at(p_plan, p_cum, clampf(p_s - h, 0.0, total))
	var b := plan_point_at(p_plan, p_cum, clampf(p_s + h, 0.0, total))
	var d := b - a
	return d.normalized() if d.length() > 1e-6 else Vector2.RIGHT


## Closest point on the plan polyline to `p_at`, as `[distance, s, side]`:
##   distance — metres from `p_at` to the centreline, always positive
##   s        — arc length of that closest point, metres from the start of the run
##   side     — +1 RIGHT of the direction of travel, -1 left, 0 exactly on it. (In the (x, z) plane the
##              2D cross below is positive at +Z for a +X heading, and left of +X is -Z.)
##
## Exact, by projecting onto each segment and keeping the best. Brute force over segments: a road brush's
## plan is tens to a few hundred points and this runs per CELL, so a uniform bucket index over segment
## bounds is the obvious optimisation — deliberately NOT done here, because the native port is where that
## belongs and a spatial index in the reference kernel would make the A/B against it compare two different
## algorithms rather than two backends.
static func nearest_on_plan(p_plan: PackedVector2Array, p_cum: PackedFloat32Array,
		p_at: Vector2) -> Array:
	if ClassDB.class_has_method("Pasture3DUtil", "road_plan_nearest"):
		return Pasture3DUtil.road_plan_nearest(p_plan, p_cum, p_at)
	var n := p_plan.size()
	if n == 0:
		return [INF, 0.0, 0.0]
	if n == 1:
		return [p_at.distance_to(p_plan[0]), 0.0, 0.0]

	var best_d2 := INF
	var best_s := 0.0
	var best_side := 0.0
	for i in range(n - 1):
		var a := p_plan[i]
		var b := p_plan[i + 1]
		# Quick bounding-box rejection: if point is farther from segment AABB than best_d2, skip projection
		var min_x := minf(a.x, b.x)
		var max_x := maxf(a.x, b.x)
		var min_y := minf(a.y, b.y)
		var max_y := maxf(a.y, b.y)
		var dx := maxf(0.0, maxf(min_x - p_at.x, p_at.x - max_x))
		var dy := maxf(0.0, maxf(min_y - p_at.y, p_at.y - max_y))
		if dx * dx + dy * dy >= best_d2:
			continue
		var ab := b - a
		var len2 := ab.length_squared()
		if len2 <= 0.0:
			continue
		# t is the projection parameter CLAMPED so the closest point stays on the segment — which is what
		# makes the union over segments the true distance to the polyline rather than to its infinite lines.
		var t := clampf((p_at - a).dot(ab) / len2, 0.0, 1.0)
		var proj := a + ab * t
		var d2 := p_at.distance_squared_to(proj)
		if d2 < best_d2:
			best_d2 = d2
			best_s = p_cum[i] + sqrt(len2) * t
			# 2D cross of the travel direction with the offset: its sign is which side we are on, and it
			# stays well defined where the distance itself is zero.
			best_side = signf(ab.x * (p_at.y - a.y) - ab.y * (p_at.x - a.x))
	return [sqrt(best_d2), best_s, best_side]


## Grade a heightfield around one road.
##
## `p_height` is row-major gw × gh, world X increasing along a row, in METRES, and may contain NaN for
## cells outside the brush's own loop — those are passed through untouched, which is what keeps the
## brush-loop boundary contract intact.
##
## The per-sample arrays are indexed by ALIGNMENT sample, so a width or a surface that changes partway
## along the run (§4.4) is just a different value at a different index. A true `p_suppress[i]` leaves the
## terrain alone at that arc length — a bridge deck carries the road, so grading under it would build the
## earth dam across the valley that the bridge exists to avoid.
##
## Returns `{height, roadbed, cut, fill, verge, structure, surface}`; every mask is 0..1 over the same
## grid.
static func grade(p_height: PackedFloat32Array, p_gw: int, p_gh: int, p_min_x: float, p_min_z: float,
		p_vs: float, p_plan: PackedVector2Array, p_alignment: Pasture3DRoadAlignment,
		p_half_width: PackedFloat32Array, p_shoulder: PackedFloat32Array,
		p_verge: PackedFloat32Array, p_suppress: PackedByteArray,
		p_opts: Dictionary = {}) -> Dictionary:
	if not ClassDB.class_has_method("Pasture3DUtil", "road_grade_grid"):
		push_error("[Pasture3D] Pasture3DUtil.road_grade_grid is not bound. Rebuild GDExtension.")
		return _pass_through(p_height, p_gw * p_gh)

	# The alignment is flattened to the four numbers the grade actually reads. A null or unsolved one is
	# handed to the kernel as an empty profile rather than short-circuited here, so the pass-through answer
	# has ONE definition — the destructive alternative being a grader that returns zeros for a road that is
	# merely being renamed.
	var ds: float = p_alignment.ds if p_alignment != null else 1.0
	var s0: float = p_alignment.s0 if p_alignment != null else 0.0
	var az: PackedFloat32Array = p_alignment.z if p_alignment != null else PackedFloat32Array()
	var bank: PackedFloat32Array = p_alignment.bank if p_alignment != null else PackedFloat32Array()
	var res: Dictionary = Pasture3DUtil.road_grade_grid(p_height, p_gw, p_gh, p_min_x, p_min_z, p_vs,
			p_plan, ds, s0, az, bank, p_half_width, p_shoulder, p_verge, p_suppress, p_opts)
	return res


## The safe answer when the kernel is missing: the ground, untouched, and no earthworks reported. Not
## zeros — a grader that flattened a terrain because a symbol was missing would be the silent degradation
## the native separation exists to delete.
static func _pass_through(p_height: PackedFloat32Array, p_n: int) -> Dictionary:
	return {
		"ok": false, "height": p_height.duplicate(),
		"roadbed": _zeros(p_n), "cut": _zeros(p_n), "fill": _zeros(p_n),
		"verge": _zeros(p_n), "structure": _zeros(p_n), "surface": _zeros(p_n),
	}


## The GDScript REFERENCE grade — the oracle `grade` is measured against by RoadNativeParityGate [F], and
## the place the argument for every rule below is written down.
##
## Not dead code and not a fallback: it is the definition. It is kept in production rather than in a gate
## for the reason every oracle in this codebase is — a definition that lives only in a test drifts from
## the thing it defines, and here the thing it defines is the shape of every road in the project.
static func grade_reference(p_height: PackedFloat32Array, p_gw: int, p_gh: int, p_min_x: float,
		p_min_z: float, p_vs: float, p_plan: PackedVector2Array, p_alignment: Pasture3DRoadAlignment,
		p_half_width: PackedFloat32Array, p_shoulder: PackedFloat32Array,
		p_verge: PackedFloat32Array, p_suppress: PackedByteArray,
		p_opts: Dictionary = {}) -> Dictionary:
	var n := p_gw * p_gh
	var out := {
		"height": p_height.duplicate(),
		"roadbed": _zeros(n), "cut": _zeros(n), "fill": _zeros(n),
		"verge": _zeros(n), "structure": _zeros(n), "surface": _zeros(n),
	}
	if p_alignment == null or p_alignment.count() == 0 or p_plan.size() < 2 or n <= 0:
		return out

	var crown: float = float(p_opts.get("crown", 0.05))
	var crown_mode: int = int(p_opts.get("crown_mode", 0))
	var max_bank: float = float(p_opts.get("max_bank", 0.0))
	var cut_batter: float = maxf(float(p_opts.get("cut_batter", 1.0)), 0.01)
	var fill_batter: float = maxf(float(p_opts.get("fill_batter", 0.6)), 0.01)
	var toe_round: float = maxf(float(p_opts.get("toe_rounding", 0.0)), 0.0)
	var hinge_round: float = maxf(float(p_opts.get("hinge_rounding", 0.0)), 0.0)
	# The retaining walls, one record per alignment sample and side (`build_wall_plan`). Empty = none.
	var wall_plan: PackedFloat32Array = p_opts.get("wall_plan", PackedFloat32Array())
	# `skip` is NOT `p_suppress`. Suppress means "a structure carries the road here", and says so in the
	# structure mask. Skip means "this arc length belongs to something else" — a junction footprint the
	# approach was trimmed back from (§6) — and must leave no trace at all: marking it as a bridge deck
	# would tell every later phase to build a viaduct at every crossroads.
	var skip: PackedByteArray = p_opts.get("skip", PackedByteArray())
	# ---- A BATTER MAY NOT CUT THROUGH ANOTHER ROAD'S FORMATION ----
	#
	# `protect` is grid-shaped, not per-sample like `skip`: it marks CELLS another road has already built
	# on. Every other mask here is indexed by this road's arc length, which cannot express "somebody
	# else's carriageway is over there" at all.
	#
	# The corridor reaches `edge_d + rise/slope + verge`, which for a road in an 8 m cutting is seventeen
	# metres of sideways reach. Two roads crossing at different heights therefore sweep their batters
	# straight across each other's carriageway, and whichever bakes LAST wins: the earlier road's ribbon
	# is left spanning a trench the later road dug under it. Measured on a plain crossing of a road at
	# grade and a road in an 8 m cutting: 225 of the first road's 729 carriageway cells were lowered, the
	# worst by the full 8 m.
	#
	# Scene order deciding it is the same fault §5.2 names for the paint, and the answer here is stronger
	# than ordering because it is not a tie-break: a batter is EARTHWORK AROUND a road, and no road's
	# earthwork outranks another road's driving surface whatever their priorities. Only the batter is
	# refused. A cell inside this road's own formation still grades — two carriageways genuinely
	# overlapping is a junction, and junctions are resolved by `skip` and the footprint polygon, not here.
	var protect: PackedByteArray = p_opts.get("protect", PackedByteArray())
	# ---- THE JUNCTION'S OWN GROUND, AND ONLY THAT ----
	#
	# `exclude` is the ground consumer's version of `skip`, and it is a different SHAPE on purpose.
	#
	# `skip` is per arc-length sample, so refusing on it refuses the cell at EVERY lateral distance out to
	# `reach` — seventeen metres each side on a road in a cutting. A junction trims its approaches back by
	# ~20 m, so that is a 40 m by 34 m swath of corridor that this road stops grading; and what then
	# grades it is `grade_junction_footprints`, which writes only the cells INSIDE the footprint polygon.
	# The polygon is about a carriageway wide. Everything between its edge and the corridor reach — the
	# shoulder, verge and batter running alongside the intersection — was claimed by neither, and stayed
	# raw hillside standing over the road. That is the ring-shaped gap around a junction.
	#
	# So the ground refuses by CELL, matching the polygon exactly: inside it the junction grades, outside
	# it this road's corridor does, and the two partition the ground with no seam and no hole. `skip`
	# keeps its per-sample shape for the RIBBON, which is a strip and is genuinely trimmed at an arc
	# length — the same two-consumers split §6 already draws, applied one level down.
	#
	# Refused before `nearest_on_plan` because it needs nothing from it: whose cell this is, is settled.
	var exclude: PackedByteArray = p_opts.get("exclude", PackedByteArray())
	var cum := cumulative_length(p_plan)
	var graded: PackedFloat32Array = out["height"]
	var m_bed: PackedFloat32Array = out["roadbed"]
	var m_cut: PackedFloat32Array = out["cut"]
	var m_fill: PackedFloat32Array = out["fill"]
	var m_verge: PackedFloat32Array = out["verge"]
	var m_struct: PackedFloat32Array = out["structure"]
	var m_surface: PackedFloat32Array = out["surface"]
	# How far past the edge of formation the painted surface fades out, in SHOULDERS rather than metres:
	# a farm track and a motorway should not share an edge width, and the shoulder is already the road's
	# own statement of how wide its margin is.
	var fade: float = maxf(float(p_opts.get("surface_fade", 1.0)), 0.0)

	for iz in range(p_gh):
		var wz := p_min_z + float(iz) * p_vs
		var row := iz * p_gw
		for ix in range(p_gw):
			var idx := row + ix
			var ground := p_height[idx]
			# NaN is the brush's "not my cell" marker, not a height. Writing a road through it would
			# invent ground outside the loop.
			if not is_finite(ground):
				continue
			if idx < exclude.size() and exclude[idx] != 0:
				continue
			var wx := p_min_x + float(ix) * p_vs

			var hit := nearest_on_plan(p_plan, cum, Vector2(wx, wz))
			var d: float = hit[0]
			var s: float = hit[1]
			var side: float = hit[2]

			var si := p_alignment.index_at(s)
			if si < skip.size() and skip[si] != 0:
				continue
			var half: float = _at(p_half_width, si, 3.5)
			var shoulder: float = _at(p_shoulder, si, 0.5)
			var verge: float = _at(p_verge, si, 4.0)
			var edge_d := half + shoulder
			# THE CORRIDOR IS AS WIDE AS THE BATTER NEEDS, plus the verge.
			#
			# It used to be `edge_d + verge`, which silently CLIPPED the batter: a 20 m cut with a 1:1
			# batter needs 20 m of run, and with a 4 m verge it got 4 — the remaining 16 m became a sheer
			# vertical wall down the side of the road. It looked like a canyon and reported no error,
			# because a clipped batter is still a legal height field.
			#
			# The run needed is (height to make up) / (batter slope), so it is computed here rather than
			# authored. `verge` keeps its meaning — disturbed ground BEYOND where the batter lands — and
			# stops being an accidental cap on how deep a cutting may be.
			var z_ref: float = p_alignment.height_at(s)
			var rise := absf(z_ref - ground)
			var slope: float = cut_batter if z_ref < ground else fill_batter
			# Plus the rounding, which reaches past the unrounded toe: the hinge pushes the batter out by
			# about its radius, and the toe fillet spreads its own width beyond that.
			var reach := edge_d + rise / slope + verge + toe_round + 2.0 * hinge_round
			# A wall's flat ground and the batter past it can reach further than the plain batter.
			if not wall_plan.is_empty():
				reach = maxf(reach, edge_d + wall_reach(wall_plan, s, p_alignment.ds, p_alignment.s0, rise)
						+ verge + toe_round)
			if d > reach:
				continue
			# Another road's formation. Refused before the suppress branch so a protected cell reports
			# nothing either: this road did not build here, and saying it did would put a bridge deck or a
			# verge in a mask that a scatter or a paint would then act on.
			if d > edge_d and idx < protect.size() and protect[idx] != 0:
				continue

			# A suppressed stretch still REPORTS itself — the structure mask is how a later phase learns
			# where to build a deck — it just does not touch the ground.
			if si < p_suppress.size() and p_suppress[si] != 0:
				m_struct[idx] = 1.0
				continue

			# The road surface across the carriageway: the solved centreline height, banked by the
			# superelevation the alignment already carries, and crowned so water sheds to the edges. Both
			# are offsets from the centreline, so both are read at the SIGNED across-distance.
			var u := d * side
			var z_road: float = p_alignment.height_at(s)
			var bank: float = p_alignment.bank[si] if si < p_alignment.bank.size() else 0.0
			var z_surface := surface_height(z_road, bank, crown, u, half, crown_mode, max_bank)

			var h := ground
			if d <= edge_d:
				h = z_surface
			else:
				# Beyond the shoulder the batter runs from the edge of formation down (fill) or up (cut)
				# until it MEETS the ground, and the meet is a max/min rather than a solved crossing —
				# which is what makes the join continuous with no seam to chase, at any terrain slope.
				var z_edge := surface_height(z_road, bank, crown, edge_d * side, half, crown_mode, max_bank)
				var g1 := edge_slope(z_road, bank, crown, edge_d, side, half, crown_mode, max_bank) \
						if hinge_round > 0.0 else 0.0
				if wall_plan.is_empty():
					h = batter_height(ground, z_edge, g1, d - edge_d, cut_batter, fill_batter, toe_round,
							hinge_round)
				else:
					h = walled_height(ground, z_edge, g1, d - edge_d, cut_batter, fill_batter, toe_round,
							hinge_round, wall_record_at(wall_plan, s, p_alignment.ds, p_alignment.s0, side))

			graded[idx] = h
			# Coverage masks. `roadbed` is the carriageway ONLY — the shoulder is not driving surface and
			# a later phase paints it differently — and `verge` is everything the road disturbed outside
			# the formation, which is what a prop scatter wants to avoid and a grass blend wants to follow.
			# COVERAGE FOR PAINTING, as a float, and computed here because this is the only place that
			# knows `d`. The binary roadbed mask says where the carriageway is; this says how much of the
			# surface material a cell should receive, which is what a control-map paint needs and what a
			# consumer cannot recover from a 0/1 mask without re-measuring the road.
			#
			# Solid out to the edge of formation, then eased to nothing over `fade` shoulders. Smoothstep
			# rather than linear, so the painted edge has no visible line where the gradient starts — which
			# a linear ramp does have, because its derivative jumps.
			var fade_end := edge_d + shoulder * fade
			if d <= edge_d:
				m_surface[idx] = 1.0
			elif fade_end > edge_d:
				var u_fade := clampf((fade_end - d) / (fade_end - edge_d), 0.0, 1.0)
				m_surface[idx] = u_fade * u_fade * (3.0 - 2.0 * u_fade)
			if d <= half:
				m_bed[idx] = 1.0
			elif d > edge_d:
				m_verge[idx] = 1.0
			if d > edge_d and absf(h - ground) <= EARTHWORK_EPSILON:
				m_verge[idx] = 1.0 # past the batter toe: disturbed ground the road did not have to move
			var delta := h - ground
			if delta > EARTHWORK_EPSILON:
				m_fill[idx] = 1.0
			elif delta < -EARTHWORK_EPSILON:
				m_cut[idx] = 1.0

	out["height"] = graded
	return out


static func _at(p_arr: PackedFloat32Array, p_i: int, p_default: float) -> float:
	if p_arr.is_empty():
		return p_default
	return p_arr[clampi(p_i, 0, p_arr.size() - 1)]


static func _zeros(p_n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(p_n)
	a.fill(0.0)
	return a
