// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Measure — reduce a field to two numbers (min/max, two percentiles, or mean/std dev) that a wire can
// carry into any scalar port. The graph node is Pasture3DGraphNodeMeasure; its GDScript oracle is
// Pasture3DGraphNodeDevMeasure, and every rule below is the oracle's, not a second choice:
//
//   * A cell COUNTS when its value is finite and, if a selection is given, its selection is >= 0.5. A brush
//     hands the graph NaN outside its footprint, so NaN-skipping is the footprint rule.
//   * PERCENTILE is EXACT, not binned: rank r = p/100 * (N - 1) over the sorted counted values, linearly
//     interpolated between the two neighbouring ranks in double. Exact so the CPU, the GPU (which reduces
//     on the host with this function) and the oracle agree by construction rather than within a bin.
//   * MEAN and the population STD DEV are summed in double in CELL-INDEX order, single-threaded, so the
//     oracle's sequential sum is the same sum.
//   * No counted cell: both values are 0 and `count` is 0. The node warns rather than handing NaN to a
//     scalar port, where the native route and the script route read a NaN differently.

#ifndef PASTURE_3D_MEASURE_H
#define PASTURE_3D_MEASURE_H

#include <cstdint>

namespace godot {

// Sync with Pasture3DGraphNodeMeasure.Mode. Values are serialised: append only.
enum MeasureMode {
	MEASURE_RANGE = 0, // a = min, b = max
	MEASURE_PERCENTILE = 1, // a = low percentile, b = high percentile
	MEASURE_MEAN = 2, // a = mean, b = population standard deviation
};

struct MeasureResult {
	double a = 0.0;
	double b = 0.0;
	int64_t count = 0;
};

// `p_selection` may be nullptr (every finite cell counts). Percentiles are clamped to [0, 100].
MeasureResult measure_field(const float *p_values, const float *p_selection, int p_n, int p_mode,
		double p_low_pct, double p_high_pct);

} // namespace godot

#endif // PASTURE_3D_MEASURE_H
