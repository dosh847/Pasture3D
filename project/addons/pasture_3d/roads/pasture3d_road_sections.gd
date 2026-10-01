# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadSections — a road cut into STRETCHES by its segments, and the blend between them. See
# PASTURE3D_ROAD_SEGMENT_SECTIONS_SPEC.md.
#
# ---- WHY ONE KERNEL ----
#
# Every consumer of a road setting — the grader, the solver, the ribbon, the paint, the junctions — used
# to ask the brush for the road's value once, and a few of them asked per sample with a hard step at the
# segment edge. A setting that reached the grader and not the mesher graded a six-lane formation under a
# two-lane ribbon. So the stretch layout, the transitions and the per-level values are computed HERE,
# once, and every consumer reads the same numbers at the same arc length.
#
# ---- LEVELS, STRETCHES, TRANSITIONS ----
#
# A LEVEL is one resolved set of road values: level 0 is the road itself, level k + 1 is segment k. The
# segment edges cut the road into STRETCHES, each owned by the last segment covering it (or the road), and
# adjacent stretches with the same owner merge. Each boundary between two stretches is a TRANSITION
# centred on it, `transition_length` long, clamped to half of each stretch so two never overlap.
#
# A continuous value runs across a transition with a smoothstep weight. A discrete one (a bridge, a kerb,
# the ribbon on or off) switches AT the boundary — `level_at` — exactly where the segment's range says.
@tool
class_name Pasture3DRoadSections
extends RefCounted

## The continuous values every level carries. Blended across a transition; see `numbers`.
const NUMBERS: Array[StringName] = [
	&"half", &"shoulder", &"verge", &"crown", &"max_bank", &"cut_batter", &"fill_batter",
	&"toe_rounding", &"hinge_rounding", &"widen_factor", &"widen_max", &"max_grade", &"k_crest",
	&"k_sag", &"design_speed", &"bank_cap", &"hairpin", &"drape",
]

## One Dictionary per level; level 0 is the road. See the header.
var levels: Array = []
## The road's arc length the stretches cover.
var total: float = 0.0
## The stretches, as parallel arrays: `[from_s[j], to_s[j])` is owned by `level[j]`.
var from_s := PackedFloat32Array()
var to_s := PackedFloat32Array()
var level := PackedInt32Array()
## Half the transition at the START of stretch `j` (the boundary with `j - 1`); 0 for the first.
var half_at := PackedFloat32Array()


## Build the stretches. `p_ranges` holds one `[start, end, transition_length]` per segment, in array
## order, and segment k is level k + 1. A segment covering nothing contributes no edge.
static func build(p_levels: Array, p_ranges: Array, p_total: float) -> Pasture3DRoadSections:
	var out := Pasture3DRoadSections.new()
	out.levels = p_levels
	out.total = maxf(p_total, 0.0)
	var cuts := PackedFloat32Array([0.0, out.total])
	for r in p_ranges:
		if float(r[1]) - float(r[0]) <= 0.0:
			continue
		cuts.append(clampf(float(r[0]), 0.0, out.total))
		cuts.append(clampf(float(r[1]), 0.0, out.total))
	cuts.sort()
	for i in range(1, cuts.size()):
		var a := cuts[i - 1]
		var b := cuts[i]
		if b - a <= 1e-4:
			continue
		var mid := (a + b) * 0.5
		# The LAST covering segment owns it: the rule `segment_at` states, and the one array order means.
		var lv := 0
		for k in p_ranges.size():
			var r: Array = p_ranges[k]
			if mid >= float(r[0]) and mid < float(r[1]):
				lv = k + 1
		var n := out.level.size()
		if n > 0 and out.level[n - 1] == lv:
			out.to_s[n - 1] = b
			continue
		out.from_s.append(a)
		out.to_s.append(b)
		out.level.append(lv)
	if out.level.is_empty():
		out.from_s.append(0.0)
		out.to_s.append(out.total)
		out.level.append(0)
	out.half_at.resize(out.level.size())
	out.half_at.fill(0.0)
	for j in range(1, out.level.size()):
		# The later of the two levels is the segment whose edge this is (see the spec, §2.3): the earlier
		# one cannot own the far side unless something later took it.
		var lv := maxi(out.level[j - 1], out.level[j])
		var length := float(p_ranges[lv - 1][2]) if lv > 0 else 0.0
		out.half_at[j] = minf(maxf(length, 0.0) * 0.5, minf(
				(out.to_s[j - 1] - out.from_s[j - 1]) * 0.5, (out.to_s[j] - out.from_s[j]) * 0.5))
	return out


## The stretch containing `p_s`, half-open like a segment's own range; the last stretch keeps the end.
func stretch_at(p_s: float) -> int:
	var j := from_s.bsearch(p_s, false) - 1
	return clampi(j, 0, level.size() - 1)


## The level that OWNS `p_s`: what a discrete setting reads. No blend.
func level_at(p_s: float) -> int:
	return level[stretch_at(p_s)]


## The level record in force at `p_s`, for a discrete read.
func values_at(p_s: float) -> Dictionary:
	return levels[level_at(p_s)]


## `[from_level, to_level, weight]` at `p_s`: a continuous value there is
## `lerp(levels[from][f], levels[to][f], weight)`.
func blend_at(p_s: float) -> Array:
	var j := stretch_at(p_s)
	if j > 0 and half_at[j] > 0.0 and p_s < from_s[j] + half_at[j]:
		return [level[j - 1], level[j], _weight(p_s, from_s[j], half_at[j])]
	if j + 1 < level.size() and half_at[j + 1] > 0.0 and p_s >= to_s[j] - half_at[j + 1]:
		return [level[j], level[j + 1], _weight(p_s, to_s[j], half_at[j + 1])]
	return [level[j], level[j], 0.0]


static func _weight(p_s: float, p_at: float, p_half: float) -> float:
	var t := clampf((p_s - (p_at - p_half)) / (2.0 * p_half), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## One continuous value at `p_s`.
func number_at(p_field: StringName, p_s: float) -> float:
	var b := blend_at(p_s)
	return lerpf(float(levels[b[0]][p_field]), float(levels[b[1]][p_field]), float(b[2]))


## True when nothing varies along the road: one stretch, so every value is level 0's.
func is_uniform() -> bool:
	return level.size() == 1


## The blend at every sample `i * p_ds`, `i < p_n`, as `{from, to, weight, owner}`, walked once so the
## per-field arrays below cost one pass each.
func sample(p_ds: float, p_n: int) -> Dictionary:
	var la := PackedInt32Array()
	var lb := PackedInt32Array()
	var w := PackedFloat32Array()
	var owner := PackedInt32Array()
	la.resize(p_n)
	lb.resize(p_n)
	w.resize(p_n)
	owner.resize(p_n)
	if is_uniform():
		la.fill(level[0])
		lb.fill(level[0])
		w.fill(0.0)
		owner.fill(level[0])
		return {"from": la, "to": lb, "weight": w, "owner": owner, "ds": p_ds, "n": p_n}
	# ONE WALK, the samples ascending, rather than `blend_at` and `level_at` per sample: those allocate and
	# bsearch every time, and this runs for every road on every bake (the protect mask samples every other
	# road too). The stretch advances exactly as `stretch_at` picks it -- the last `from_s` at or before s
	# -- and the blend is `blend_at`'s, inlined.
	var j := 0
	var last := level.size() - 1
	for i in p_n:
		var s := float(i) * p_ds
		while j < last and from_s[j + 1] <= s:
			j += 1
		var a := level[j]
		var b := a
		var t := 0.0
		if j > 0 and half_at[j] > 0.0 and s < from_s[j] + half_at[j]:
			a = level[j - 1]
			b = level[j]
			t = _weight(s, from_s[j], half_at[j])
		elif j < last and half_at[j + 1] > 0.0 and s >= to_s[j] - half_at[j + 1]:
			b = level[j + 1]
			t = _weight(s, to_s[j], half_at[j + 1])
		la[i] = a
		lb[i] = b
		w[i] = t
		owner[i] = level[j]
	return {"from": la, "to": lb, "weight": w, "owner": owner, "ds": p_ds, "n": p_n}


## One continuous value at every sample of `p_sampled` (from `sample`).
func numbers(p_field: StringName, p_sampled: Dictionary) -> PackedFloat32Array:
	var n: int = p_sampled["n"]
	var out := PackedFloat32Array()
	out.resize(n)
	if is_uniform():
		out.fill(float(levels[0][p_field]))
		return out
	var la: PackedInt32Array = p_sampled["from"]
	var lb: PackedInt32Array = p_sampled["to"]
	var w: PackedFloat32Array = p_sampled["weight"]
	var vals := PackedFloat32Array()
	for lv in levels:
		vals.append(float(lv[p_field]))
	for i in n:
		out[i] = lerpf(vals[la[i]], vals[lb[i]], w[i])
	return out


## One discrete value at every sample, as the owning level's, packed as bytes.
func bytes(p_field: StringName, p_sampled: Dictionary) -> PackedByteArray:
	var n: int = p_sampled["n"]
	var owner: PackedInt32Array = p_sampled["owner"]
	var out := PackedByteArray()
	out.resize(n)
	for i in n:
		out[i] = int(levels[owner[i]][p_field])
	return out


## The arc lengths where a discrete setting can change: every stretch boundary. What the chunker cuts on.
func boundaries() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for j in range(1, level.size()):
		out.append(from_s[j])
	return out


## Everything a consumer of these sections depends on, for a cache key: the layout, the transitions,
## and the value of `p_fields` in every level. Values that are Objects sign by identity.
func signature(p_fields: Array) -> Array:
	var vals: Array = []
	for lv in levels:
		var row: Array = []
		for f in p_fields:
			var v: Variant = lv.get(f)
			row.append(v.get_instance_id() if v is Object else v)
		vals.append(row)
	return [from_s, to_s, level, half_at, vals]
