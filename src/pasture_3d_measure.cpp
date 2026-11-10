// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_measure.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

namespace godot {

namespace {

bool counts(const float *p_values, const float *p_selection, int p_i) {
	if (!std::isfinite(p_values[p_i])) {
		return false;
	}
	// A NaN selection fails the comparison, so it excludes the cell like any value under the cut.
	return p_selection == nullptr || p_selection[p_i] >= 0.5f;
}

// Rank p/100 * (N - 1) of `r_v`, interpolated in double. Reorders `r_v` (nth_element), which a second call
// does not care about: any permutation of the same values answers the same rank.
double percentile_of(std::vector<float> &r_v, double p_pct) {
	const size_t n = r_v.size();
	const double r = std::clamp(p_pct, 0.0, 100.0) / 100.0 * (double)(n - 1);
	const size_t i = std::min((size_t)std::floor(r), n - 1);
	const double f = r - (double)i;
	std::nth_element(r_v.begin(), r_v.begin() + (ptrdiff_t)i, r_v.end());
	const double lo = (double)r_v[i];
	if (f <= 0.0 || i + 1 >= n) {
		return lo;
	}
	// Everything after the nth element is >= it, so the next rank is the smallest of them.
	const double hi = (double)*std::min_element(r_v.begin() + (ptrdiff_t)(i + 1), r_v.end());
	return lo + f * (hi - lo);
}

} // namespace

MeasureResult measure_field(const float *p_values, const float *p_selection, int p_n, int p_mode,
		double p_low_pct, double p_high_pct) {
	MeasureResult r;
	if (p_values == nullptr || p_n <= 0) {
		return r;
	}
	switch (p_mode) {
		case MEASURE_PERCENTILE: {
			std::vector<float> v;
			v.reserve((size_t)p_n);
			for (int i = 0; i < p_n; i++) {
				if (counts(p_values, p_selection, i)) {
					v.push_back(p_values[i]);
				}
			}
			r.count = (int64_t)v.size();
			if (!v.empty()) {
				r.a = percentile_of(v, p_low_pct);
				r.b = percentile_of(v, p_high_pct);
			}
		} break;
		case MEASURE_MEAN: {
			double sum = 0.0;
			for (int i = 0; i < p_n; i++) {
				if (counts(p_values, p_selection, i)) {
					sum += (double)p_values[i];
					r.count++;
				}
			}
			if (r.count > 0) {
				r.a = sum / (double)r.count;
				// Two-pass: the textbook one-pass E[x^2] - E[x]^2 cancels catastrophically on a 300 m
				// plateau whose spread is a few metres.
				double ss = 0.0;
				for (int i = 0; i < p_n; i++) {
					if (counts(p_values, p_selection, i)) {
						const double d = (double)p_values[i] - r.a;
						ss += d * d;
					}
				}
				r.b = std::sqrt(ss / (double)r.count);
			}
		} break;
		default: { // MEASURE_RANGE
			double lo = std::numeric_limits<double>::infinity();
			double hi = -std::numeric_limits<double>::infinity();
			for (int i = 0; i < p_n; i++) {
				if (counts(p_values, p_selection, i)) {
					lo = std::min(lo, (double)p_values[i]);
					hi = std::max(hi, (double)p_values[i]);
					r.count++;
				}
			}
			if (r.count > 0) {
				r.a = lo;
				r.b = hi;
			}
		} break;
	}
	return r;
}

} // namespace godot
