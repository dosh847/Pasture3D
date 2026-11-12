// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_mask_feather.h"
#include "pasture_3d_distance_transform.h"

#include <algorithm>
#include <cmath>

using namespace godot;

MaskFeatherParams godot::mask_feather_params_from(const float *p_P, int p_count) {
	MaskFeatherParams r;
	auto at = [&](int k, double d) -> double { return (p_P && k < p_count) ? (double)p_P[k] : d; };
	r.feather = std::max(at(0, r.feather), 0.0);
	r.side = std::clamp((int)std::lround(at(1, r.side)), 0, 2);
	r.falloff = at(2, r.falloff) > 0.5 ? MASK_FEATHER_SMOOTH : MASK_FEATHER_LINEAR;
	r.threshold = at(3, r.threshold);
	r.invert = at(4, 0.0) > 0.5;
	return r;
}

PackedFloat32Array godot::mask_feather_solve(const PackedFloat32Array &p_mask, int p_gw, int p_gh,
		const Rect2 &p_rect, const MaskFeatherParams &p_params) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	if (n <= 0 || p_mask.size() != n) {
		return out;
	}
	out.resize(n);
	const float *src = p_mask.ptr();
	float *dst = out.ptrw();

	// A mask with no inside, or no outside, has no edge to feather from. The distance transform reports
	// the field diagonal for a missing side, which a wide enough feather would turn into a faint uniform
	// wash — a value nothing in the input asked for.
	bool any_in = false;
	bool any_out = false;
	for (int i = 0; i < n; i++) {
		if (!std::isfinite(src[i])) {
			continue;
		}
		if (src[i] > (float)p_params.threshold) {
			any_in = true;
		} else {
			any_out = true;
		}
	}

	const double F = p_params.feather;
	auto finish = [&](double m) -> float {
		const double t = std::clamp(m, 0.0, 1.0);
		const double v = p_params.falloff == MASK_FEATHER_SMOOTH ? t * t * (3.0 - 2.0 * t) : t;
		return (float)(p_params.invert ? 1.0 - v : v);
	};

	if (!any_in || !any_out) {
		const float c = finish(any_in ? 1.0 : 0.0);
		for (int i = 0; i < n; i++) {
			dst[i] = std::isfinite(src[i]) ? c : src[i];
		}
		return out;
	}

	double divisor = 1.0;
	const PackedFloat32Array sd = distance_transform_solve(p_mask, p_gw, p_gh, p_rect, p_params.threshold,
			DISTANCE_TRANSFORM_SIGNED, DISTANCE_TRANSFORM_EUCLIDEAN, DISTANCE_TRANSFORM_METRES, 0.0, &divisor);
	if (sd.size() != n) {
		out.resize(0);
		return out;
	}
	const float *d = sd.ptr();

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double half = 0.5 * std::min(dx, dz);

	for (int i = 0; i < n; i++) {
		if (!std::isfinite(src[i])) {
			dst[i] = src[i];
			continue;
		}
		const bool inside = src[i] > (float)p_params.threshold;
		// Signed distance from the CONTOUR: positive outside, negative inside, half a cell back from the
		// centre-to-centre distance the transform measures.
		const double e = inside ? std::min((double)d[i] + half, 0.0) : std::max((double)d[i] - half, 0.0);
		double m;
		switch (p_params.side) {
			case MASK_FEATHER_INWARD:
				m = inside ? (F <= 0.0 ? 1.0 : -e / F) : 0.0;
				break;
			case MASK_FEATHER_CENTRED:
				m = F <= 0.0 ? (inside ? 1.0 : 0.0) : 0.5 - e / F;
				break;
			case MASK_FEATHER_OUTWARD:
			default:
				m = inside ? 1.0 : (F <= 0.0 ? 0.0 : 1.0 - e / F);
				break;
		}
		dst[i] = finish(m);
	}
	return out;
}
