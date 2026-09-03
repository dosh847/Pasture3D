# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadAlignment — the SOLVED vertical profile of one road run, sampled uniformly along its
# centreline: how high the road is at every metre, how steeply it climbs there, and how far it is banked.
# Produced by Pasture3DRoadAlignmentSolver; see PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §7.
#
# ---- THIS IS THE DIFFERENCE BETWEEN A ROAD AND A RIBBON ----
#
# The plan alignment (where the road goes in XZ) is authored on the spline. The VERTICAL alignment is
# not: it is solved, subject to a hard gradient limit, by trading cut against fill. A road that simply
# drapes on the terrain reads as a ribbon laid over a hill, because a real road cuts through the crest
# and fills the dip rather than following either.
#
# ---- WHAT ELSE FALLS OUT OF IT ----
#
# Two things come free once this exists, and neither is available to a draped road:
#
#   * BANKING. Plan curvature gives superelevation by v²·κ/g, which is physics rather than styling, and
#     is the same number a racing track wants. It is baked into the run's Curve3D tilt, so a game reads
#     it straight out of `Curve3D.sample_baked_up_vector()`.
#   * PACE NOTES (P6). Corner severity is κ; "crest" and "dip" are the sign of d²z/ds² — of the SOLVED
#     profile. On a draped road that second derivative is terrain noise, not road geometry, so the calls
#     would be nonsense. `curvature` and `z` are kept here for exactly that consumer.
#
# Sampling is uniform in arc length (`ds` metres apart, starting at `s0`), which is what makes every
# query below an index rather than a search.
@tool
class_name Pasture3DRoadAlignment
extends Resource

## Arc-length spacing between samples, metres.
@export var ds: float = 1.0
## Arc length of the first sample, metres from the start of the run.
@export var s0: float = 0.0
## Solved road surface height at each sample, metres. The answer this whole class exists to carry.
@export var z: PackedFloat32Array = PackedFloat32Array():
	set(v):
		z = v
		_deepest = -1.0
## Terrain height under each sample, metres — kept so cut/fill can be re-derived and so a later phase
## can grade the ground toward `z` without re-sampling the heightmap.
@export var ground: PackedFloat32Array = PackedFloat32Array():
	set(v):
		ground = v
		_deepest = -1.0
## Signed plan curvature at each sample, 1/metres. Positive turns left. Drives banking, and is the
## corner-severity input for pace notes.
@export var curvature: PackedFloat32Array = PackedFloat32Array()
## Superelevation at each sample as a rise/run RATIO across the carriageway, signed like `curvature`.
@export var bank: PackedFloat32Array = PackedFloat32Array()
## Sample indices whose height was pinned by the designer and not solved for.
@export var pinned: PackedInt32Array = PackedInt32Array()

@export_group("Diagnostics")
## The gradient limit the solve was run under, rise/run. Kept so a result can be checked against the
## constraint it was actually given rather than against whatever the RoadType says now.
@export var max_grade_used: float = 0.08
## Steepest |dz/ds| in the result. Must not exceed `max_grade_used` by more than rounding.
@export var peak_grade: float = 0.0
## Metres³ of material removed and added (per metre of width — multiply by the road's width).
@export var cut_volume: float = 0.0
@export var fill_volume: float = 0.0
## Largest distance any pinned sample ended up from the height it was pinned to, metres. Non-zero means
## the pins asked for something the gradient limit forbids — see `Pasture3DRoadAlignmentSolver`.
@export var pin_error: float = 0.0
## False when the solve could not reach a profile satisfying the gradient limit. Never silently ignored:
## a caller that gets this should say so rather than build a road that climbs a wall.
@export var feasible: bool = true

## Digest of the INPUTS this profile was solved from — see Pasture3DRoadBrush.alignment_digest.
##
## Here rather than on the modifier because it travels with the thing it describes: an alignment handed
## around, duplicated or saved cannot become separated from the statement of what it is an answer to.
## Empty means "solved before this existed", which is treated as unusable rather than as matching.
@export var input_digest: String = ""


## Worst structure height this profile carries, memoised. -1 means "not computed since the last change".
##
## Not exported: it is derived from `z` and `ground`, and a derived value saved beside its inputs is a
## second place for them to disagree.
var _deepest: float = -1.0


## Worst height between the road and the ground anywhere on this profile, metres. Cut or fill, whichever
## is deeper — it is the allowance the corridor has to be wide enough to hold.
##
## ---- WHY THIS IS MEMOISED AND WHY IT LIVES HERE ----
##
## `Pasture3DNodeRoad._deepest_structure` scanned the whole alignment on every call — 10 000 iterations on
## a 10 km road — with no memo against the profile it had just scanned. `Pasture3DRoadBrush.corridor_half_width`
## calls it once per active road modifier, and that is called from `_padding`, `paint_bounds` (per road
## inside `_clear_paint_layers` on every resolve), `build_runtime`, `_paint_flat_footprint` twice,
## `grade_surface`, and `pick_road_screen_distance` — the last once per road brush on every editor click.
## Since S1 put `snappedf(_padding(), PAD_QUANTUM)` in the stamp key it is also read on every key
## computation, which is what turned memoising it from an optimisation into a requirement.
##
## It lives on the alignment rather than on the modifier because it is a fact about the PROFILE, and being
## here is what lets the two fields it reads invalidate it directly. A memo on the modifier keyed on
## `input_digest` — which is what the spec proposed — would go stale the moment a profile was edited
## without its INPUTS changing, and would key on the empty string for every alignment solved before that
## field existed.
##
## The reset hangs off the `z` and `ground` setters and NOT off `changed`: a plain `@export var` assignment
## in GDScript emits no `changed` at all, so a memo invalidated that way is a memo that is never
## invalidated. `[CG] edited in place` is what caught that, and it is what keeps catching it.
##
## Still expressed through `offset_at`, deliberately. That is the definition of the quantity, and reading
## `z[i] - ground[i]` here instead would put a second copy of it beside the first — including the
## out-of-range rule, which `offset_at` answers as 0.
func deepest_structure() -> float:
	if _deepest < 0.0:
		var worst := 0.0
		for i in count():
			worst = maxf(worst, absf(offset_at(i)))
		_deepest = worst
	return _deepest


## Number of samples.
func count() -> int:
	return z.size()


## Total arc length this alignment covers, metres.
func length() -> float:
	return maxf(float(count() - 1), 0.0) * ds


## Sample index nearest `p_s` metres along the run, clamped to the ends.
func index_at(p_s: float) -> int:
	if count() == 0:
		return -1
	return clampi(int(round((p_s - s0) / maxf(ds, 1e-6))), 0, count() - 1)


## Road height at `p_s` metres, linearly interpolated. NAN when there is nothing solved.
func height_at(p_s: float) -> float:
	var n := count()
	if n == 0:
		return NAN
	if n == 1:
		return z[0]
	var t := (p_s - s0) / maxf(ds, 1e-6)
	var i := clampi(int(floor(t)), 0, n - 2)
	return lerpf(z[i], z[i + 1], clampf(t - float(i), 0.0, 1.0))


## Gradient at sample `p_i`, rise/run, by central difference (one-sided at the ends). The quantity the
## solve constrains, so it is derived here rather than stored — a stored copy could disagree with `z`.
func grade_at(p_i: int) -> float:
	var n := count()
	if n < 2:
		return 0.0
	var i := clampi(p_i, 0, n - 1)
	if i == 0:
		return (z[1] - z[0]) / ds
	if i == n - 1:
		return (z[n - 1] - z[n - 2]) / ds
	return (z[i + 1] - z[i - 1]) / (2.0 * ds)


## Vertical curvature at sample `p_i`, 1/metres — the second difference of the SOLVED profile. Positive
## is a dip (sag), negative is a crest. The pace-note generator's crest/dip test, and the reason the
## solver carries a smoothness term at all.
func vertical_curvature_at(p_i: int) -> float:
	var n := count()
	if n < 3:
		return 0.0
	var i := clampi(p_i, 1, n - 2)
	return (z[i - 1] - 2.0 * z[i] + z[i + 1]) / (ds * ds)


## Height of the road above (+) or below (−) the terrain at sample `p_i`. Positive is fill, negative is
## cut. The field P2's grader turns into earthworks, and the test for a bridge or a tunnel interval.
func offset_at(p_i: int) -> float:
	if p_i < 0 or p_i >= count() or p_i >= ground.size():
		return 0.0
	return z[p_i] - ground[p_i]


## Banking as a TILT in radians about the direction of travel, which is what a Curve3D point's tilt
## wants. `bank` is stored as a ratio because that is how road engineering states it and how
## `max_superelevation` is authored.
func tilt_at(p_i: int) -> float:
	if p_i < 0 or p_i >= bank.size():
		return 0.0
	return atan(bank[p_i])


## Intervals where the road stands far enough off the ground to need a structure: `[[from_s, to_s,
## is_bridge], …]`, bridge when the road is above the terrain and a tunnel when below. Emitting the
## INTERVAL is what stops a later phase building an absurd earth dam across a valley; building the
## structure itself is a separate system and out of scope.
func structure_intervals(p_bridge_threshold: float = 6.0, p_tunnel_threshold: float = 6.0) -> Array:
	var out: Array = []
	var n := mini(count(), ground.size())
	var open := -1
	var open_bridge := false
	for i in n:
		var d := offset_at(i)
		var is_b := d > p_bridge_threshold
		var is_t := d < -p_tunnel_threshold
		var hit := is_b or is_t
		if hit and open < 0:
			open = i
			open_bridge = is_b
		elif open >= 0 and (not hit or is_b != open_bridge):
			out.append([s0 + float(open) * ds, s0 + float(i - 1) * ds, open_bridge])
			open = i if hit else -1
			open_bridge = is_b
	if open >= 0:
		out.append([s0 + float(open) * ds, s0 + float(n - 1) * ds, open_bridge])
	return out
## Everything a consumer of this alignment reads, as one int. Used by `Pasture3DGraphPath.content_digest`
## to decide whether a rebuilt path actually differs from the one a Road Source already holds.
##
## The SOLVED profile, not the diagnostics. `max_grade_used`, `peak_grade`, the volumes, `pin_error` and
## `feasible` are reports ABOUT this solve; two alignments with identical geometry and different volume
## reports grade to the same terrain, and including them would invalidate a downstream cache over a
## number nothing downstream reads. `input_digest` is likewise excluded — it identifies the INPUTS, and a
## digest of a digest of the inputs is not a digest of the result.
func content_digest() -> int:
	return hash([ds, s0, z, ground, curvature, bank, pinned])
