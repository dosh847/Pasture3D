# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevLeveler — the GDScript oracle for the Leveler (PASTURE3D_GRAPH_LEVELER_SPEC.md).
#
# Levels a height field inside an area, to a statistic of the ground already there (Flatten) or to an
# authored world height (Level at Height), and builds a feathered wall OUTSIDE the area back to the
# untouched terrain. Parameters and ports live in Pasture3DGraphNodeLevelerBase; this file is the maths.
#
# ---- THIS FILE IS THE CONTRACT THE C++ KERNEL IS GATED AGAINST ----
#
# So every rule a second implementation could pick differently is decided here, once, and written down:
# the order the mean is summed in, the histogram median's bin and interpolation rule, the LUT lookup, which
# distance rule applies to which area, and what an empty area does. src/pasture_3d_leveler.cpp mirrors each
# of them; a difference is a parity failure, not a judgement call.
#
# ---- THE BRUSH FOOTPRINT IS NOT A MASK THIS NODE RECEIVES ----
#
# A brush evaluates its graph with `p_mask = null` and composites the result through its own footprint, so
# "the footprint" is not a grid this node can read. Cells outside it reach the graph as NON-FINITE height,
# and a non-finite cell is never part of the area and never part of a statistic. That is the whole
# footprint rule: with nothing wired, the area is every finite cell, which inside a brush is the footprint
# and on a full terrain is the whole grid.
#
# ---- TWO DISTANCE RULES, CHOSEN BY THE AREA, NOT BY A SETTING ----
#
# A loop alone has an exact boundary, so its wall is measured exactly (`Pasture3DGraphPath.nearest`). Any
# area a mask shapes has only a raster boundary, so its wall is measured by the same jump flooding the
# Distance Transform runs — approximate on purpose, so CPU, GPU and this oracle agree by construction.
# A mask that is 1 on every finite cell shapes nothing, and counts as unwired: the unwired default IS 1,
# so the evaluator cannot tell the two apart, and neither should the rule.
@tool
class_name Pasture3DGraphNodeDevLeveler
extends Pasture3DGraphNodeLevelerBase


func op() -> StringName:
	return &"dev_leveler"


func display_name() -> String:
	return "[Dev/GD] Leveler" if resource_name.is_empty() else resource_name


func blocks_native() -> bool:
	return true


## Linear lookup, the rule of `raster_ramp` in pasture_3d_brush_raster.cpp.
static func sample_lut(p_lut: PackedFloat32Array, p_x: float) -> float:
	var x := clampf(p_x, 0.0, 1.0)
	var n := p_lut.size()
	var f := x * float(n - 1)
	var i0 := int(f)
	if i0 >= n - 1:
		return p_lut[n - 1]
	var frac := f - float(i0)
	return p_lut[i0] * (1.0 - frac) + p_lut[i0 + 1] * frac


## |slope| of the LUT's interval containing x, over the steepest interval. 0 for a flat LUT.
static func lut_slope(p_lut: PackedFloat32Array, p_x: float, p_max_step: float) -> float:
	if p_max_step <= 0.0:
		return 0.0
	var n := p_lut.size()
	var i0 := mini(int(clampf(p_x, 0.0, 1.0) * float(n - 1)), n - 2)
	return absf(p_lut[i0 + 1] - p_lut[i0]) / p_max_step


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var h: PackedFloat32Array = p_inputs[0] if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array \
			and p_inputs[0].size() == n else Pasture3DGraphOps.zeros(n)
	var mask_in: PackedFloat32Array = p_inputs[2] if p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array \
			and p_inputs[2].size() == n else Pasture3DGraphOps.filled(n, 1.0)
	var tgt: float = float(p_inputs[3][0]) if p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array \
			and p_inputs[3].size() > 0 else target_height

	var out_h := h.duplicate()
	var out_mask := Pasture3DGraphOps.zeros(n)
	var out_delta := Pasture3DGraphOps.zeros(n)
	var out_walls := Pasture3DGraphOps.zeros(n)

	var dx := p_rect.size.x / float(maxi(p_gw, 1))
	var dz := p_rect.size.y / float(maxi(p_gh, 1))
	var min_x := p_rect.position.x + 0.5 * dx
	var min_z := p_rect.position.y + 0.5 * dz

	# ---- 1. AREA ----
	# `area` is A in [0,1]; `core` is the fully-inside set I. A non-finite height is outside everything.
	var area := PackedFloat32Array()
	area.resize(n)
	var core := PackedByteArray()
	core.resize(n)
	var mask_trivial := true
	var core_count := 0
	for iz in p_gh:
		var row := iz * p_gw
		var wz := min_z + float(iz) * dz
		for ix in p_gw:
			var i := row + ix
			if not is_finite(h[i]):
				area[i] = 0.0
				continue
			var m := mask_in[i]
			m = clampf(m, 0.0, 1.0) if is_finite(m) else 0.0
			if m < 1.0 - CORE_EPS:
				mask_trivial = false
			var a := m
			if _path != null and not _path.inside(Vector2(min_x + float(ix) * dx, wz)):
				a = 0.0
			area[i] = a
			if a >= 1.0 - CORE_EPS:
				core[i] = 1
				core_count += 1

	evaluated = true
	last_core_count = core_count
	last_level = NAN
	var level_ch := Pasture3DGraphOps.filled(n, NAN)
	if core_count == 0:
		# Nothing is fully inside: no statistic has anything to sample, and a level at height would have no
		# flat region. Pass through — the spec's empty-set rule, decided here and mirrored by the kernel.
		return [out_h, out_mask, level_ch, out_delta, out_walls]

	# ---- 2. LEVEL ----
	var level: float = tgt if mode == Mode.LEVEL_AT_HEIGHT else _statistic(h, core, p_gw, p_gh)
	last_level = level
	level_ch = Pasture3DGraphOps.filled(n, level)

	# ---- 3. DISTANCE OUTSIDE THE CORE ----
	var exact := _path != null and mask_trivial
	var d_jfa := PackedFloat64Array()
	if not exact:
		var dt := Pasture3DGraphNodeDevDistanceTransform.new()
		d_jfa = dt._field(core, true, p_gw, p_gh, dx, dz)
	var use_width := feather_from_path_width and _path != null

	var lut := falloff_lut()
	var max_step := 0.0
	for i in LUT_SIZE - 1:
		max_step = maxf(max_step, absf(lut[i + 1] - lut[i]))

	# ---- 4. APPLY ----
	for iz in p_gh:
		var row := iz * p_gw
		var wz := min_z + float(iz) * dz
		for ix in p_gw:
			var i := row + ix
			var hv := h[i]
			if not is_finite(hv):
				continue
			var d := 0.0
			var q := {}
			if core[i] == 0:
				if exact or use_width:
					q = _path.nearest(Vector2(min_x + float(ix) * dx, wz))
				d = float(q["distance"]) if exact else d_jfa[i]
			var f_w := feather
			if use_width and core[i] == 0:
				f_w = path_width_scale * _path.half_width_at(float(q["s"]))

			var w := 1.0
			var t := 0.0
			var in_ring := false
			if core[i] == 0:
				if f_w > 0.0 and d < f_w:
					t = d / f_w
					in_ring = true
					w = maxf(area[i], sample_lut(lut, t))
				else:
					w = area[i]
			if w <= 0.0:
				continue

			var target := hv + (level - hv) * w
			var ov := target
			if cut_fill == CutFill.CUT_ONLY:
				ov = minf(hv, target)
			elif cut_fill == CutFill.FILL_ONLY:
				ov = maxf(hv, target)
			var delta := ov - hv
			out_h[i] = ov
			out_delta[i] = delta
			if cut_fill == CutFill.BOTH or delta != 0.0:
				out_mask[i] = w
			if in_ring and delta != 0.0:
				var move := 1.0 if wall_depth <= 0.0 else clampf(absf(delta) / wall_depth, 0.0, 1.0)
				var shape := 1.0 if walls_shape == WallsShape.BAND else lut_slope(lut, t, max_step)
				out_walls[i] = move * shape

	return [out_h, out_mask, level_ch, out_delta, out_walls]


## The Flatten statistic over the core. Non-finite cells are already outside it.
func _statistic(p_h: PackedFloat32Array, p_core: PackedByteArray, p_gw: int, p_gh: int) -> float:
	match statistic:
		Statistic.MIN, Statistic.MAX:
			var want_max := statistic == Statistic.MAX
			var best := -INF if want_max else INF
			for i in p_h.size():
				if p_core[i] == 1:
					best = maxf(best, p_h[i]) if want_max else minf(best, p_h[i])
			return best
		Statistic.MEDIAN:
			return _histogram_median(p_h, p_core)
	# MEAN: sum each MEAN_BLOCK_ROWS block, then add the block sums in block order.
	var total := 0.0
	var count := 0
	var z0 := 0
	while z0 < p_gh:
		var z1 := mini(z0 + MEAN_BLOCK_ROWS, p_gh)
		var block := 0.0
		for iz in range(z0, z1):
			var row := iz * p_gw
			for ix in p_gw:
				if p_core[row + ix] == 1:
					block += p_h[row + ix]
					count += 1
		total += block
		z0 = z1
	return total / float(count)


## Binned LOWER median over [min, max] of the core. Rank k = N/2; the median bin is the first whose
## cumulative count reaches k, and the value is interpolated linearly within it. All cells equal → that value.
func _histogram_median(p_h: PackedFloat32Array, p_core: PackedByteArray) -> float:
	var lo := INF
	var hi := -INF
	var count := 0
	for i in p_h.size():
		if p_core[i] == 1:
			lo = minf(lo, p_h[i])
			hi = maxf(hi, p_h[i])
			count += 1
	if hi <= lo:
		return lo
	var bins := median_bins
	var hist := PackedInt64Array()
	hist.resize(bins)
	var span := hi - lo
	for i in p_h.size():
		if p_core[i] == 1:
			hist[mini(int((p_h[i] - lo) / span * float(bins)), bins - 1)] += 1
	var k := 0.5 * float(count)
	var cum := 0
	for b in bins:
		var c := hist[b]
		if c > 0 and float(cum + c) >= k:
			return lo + (float(b) + (k - float(cum)) / float(c)) * span / float(bins)
		cum += c
	return hi
