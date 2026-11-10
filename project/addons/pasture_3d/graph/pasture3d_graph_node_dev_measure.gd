# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevMeasure — Measure in GDScript, the oracle GraphMeasureGate measures
# Pasture3DUtil.measure_field (native op 69, and the GPU's host reduction) against. Written from the rules
# in src/pasture_3d_measure.h, never from its code: a full sort where the kernel uses nth_element, so the
# two only agree if the RANK rule is the same.
@tool
class_name Pasture3DGraphNodeDevMeasure
extends Pasture3DGraphNodeMeasure


func op() -> StringName:
	return &"dev_measure"


func display_name() -> String:
	return resource_name if not resource_name.is_empty() else "[Dev/GD] Measure"


func native_lower() -> Dictionary:
	return {}


func measure(p_values: PackedFloat32Array, p_selection: PackedFloat32Array) -> PackedFloat64Array:
	return measure_gd(p_values, p_selection, mode, low_percentile, high_percentile)


static func measure_gd(p_values: PackedFloat32Array, p_selection: PackedFloat32Array, p_mode: int,
		p_low: float, p_high: float) -> PackedFloat64Array:
	var use_sel := p_selection.size() == p_values.size()
	var v := PackedFloat64Array()
	for i in p_values.size():
		var x: float = p_values[i]
		if is_finite(x) and (not use_sel or p_selection[i] >= 0.5):
			v.append(x)
	var n := v.size()
	if n == 0:
		return PackedFloat64Array([0.0, 0.0, 0.0])
	match p_mode:
		Mode.PERCENTILE:
			v.sort()
			return PackedFloat64Array([_rank(v, p_low), _rank(v, p_high), float(n)])
		Mode.MEAN:
			var sum := 0.0
			for x in v:
				sum += x
			var mean := sum / n
			var ss := 0.0
			for x in v:
				ss += (x - mean) * (x - mean)
			return PackedFloat64Array([mean, sqrt(ss / n), float(n)])
	var lo := INF
	var hi := -INF
	for x in v:
		lo = minf(lo, x)
		hi = maxf(hi, x)
	return PackedFloat64Array([lo, hi, float(n)])


## Rank p/100 * (N - 1) of a SORTED array, linearly interpolated.
static func _rank(p_sorted: PackedFloat64Array, p_pct: float) -> float:
	var n := p_sorted.size()
	var r := clampf(p_pct, 0.0, 100.0) / 100.0 * float(n - 1)
	var i := mini(int(floor(r)), n - 1)
	var f := r - float(i)
	if f <= 0.0 or i + 1 >= n:
		return p_sorted[i]
	return p_sorted[i] + f * (p_sorted[i + 1] - p_sorted[i])
