// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Coastal Erosion kernel. The model and its four steps are in pasture_3d_coastal_erosion.h.

#include "pasture_3d_coastal_erosion.h"
#include "pasture_3d_distance_transform.h"
#include "pasture_3d_erosion_thermal.h"
#include "pasture_3d_thread_pool.h"

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>
#include <vector>

using namespace godot;

CoastalErosionParams godot::coastal_erosion_params_from(const float *p_params, int p_count) {
	CoastalErosionParams r;
	auto at = [&](int i, double d) -> double { return (p_params && i < p_count) ? (double)p_params[i] : d; };
	r.sea_level = at(0, r.sea_level);
	r.retreat = std::max(at(1, r.retreat), 0.0);
	r.platform_depth = std::max(at(2, r.platform_depth), 0.0);
	r.cliff_angle = std::clamp(at(3, r.cliff_angle), 1.0, 89.0);
	r.cliff_iterations = std::clamp((int)std::lround(at(4, r.cliff_iterations)), 0, 256);
	r.beach_height = at(5, r.beach_height);
	r.beach_width = std::max(at(6, r.beach_width), 0.0);
	r.deposit = std::clamp(at(7, r.deposit), 0.0, 1.0);
	r.slack_angle = std::clamp(at(8, r.slack_angle), 1.0, 89.0);
	r.crest_reach = std::max(at(9, r.crest_reach), 0.0);
	return r;
}

Dictionary godot::coastal_erosion_grid(const PackedFloat32Array &p_height, const PackedFloat32Array &p_exposure,
		int p_gw, int p_gh, const Rect2 &p_rect, const CoastalErosionParams &p_prm) {
	Dictionary out;
	const int n = p_gw * p_gh;
	if (p_gw <= 0 || p_gh <= 0 || p_height.size() != n) {
		return out;
	}
	const CoastalErosionParams P = p_prm;
	const float *h0 = p_height.ptr();
	const float *ex = p_exposure.size() == n ? p_exposure.ptr() : nullptr;
	auto exposure_at = [&](int i) -> double {
		if (!ex) return 1.0;
		const float v = ex[i];
		return std::isfinite(v) ? std::clamp((double)v, 0.0, 1.0) : 0.0;
	};

	// 1. Distances, in metres, by the shared JFA transform. The masks mark the cells distances are
	// measured TO; a NaN cell is neither water nor land and is left out of both.
	PackedFloat32Array water_mask, land_mask;
	water_mask.resize(n);
	land_mask.resize(n);
	{
		float *wm = water_mask.ptrw();
		float *lm = land_mask.ptrw();
		for (int i = 0; i < n; i++) {
			const bool finite = std::isfinite(h0[i]);
			const bool water = finite && (double)h0[i] < P.sea_level;
			wm[i] = water ? 1.f : 0.f;
			lm[i] = (finite && !water) ? 1.f : 0.f;
		}
	}
	const PackedFloat32Array d_sea_arr = distance_transform_solve(water_mask, p_gw, p_gh, p_rect, 0.5,
			DISTANCE_TRANSFORM_OUTSIDE, DISTANCE_TRANSFORM_EUCLIDEAN, DISTANCE_TRANSFORM_METRES, 0.0, nullptr);
	const PackedFloat32Array d_land_arr = distance_transform_solve(land_mask, p_gw, p_gh, p_rect, 0.5,
			DISTANCE_TRANSFORM_OUTSIDE, DISTANCE_TRANSFORM_EUCLIDEAN, DISTANCE_TRANSFORM_METRES, 0.0, nullptr);
	if (d_sea_arr.size() != n || d_land_arr.size() != n) {
		return out;
	}
	const float *d_sea = d_sea_arr.ptr();
	const float *d_land = d_land_arr.ptr();
	const float *wm = water_mask.ptr();
	const float *lm = land_mask.ptr();

	// 2. Retreat to a wave-cut platform.
	PackedFloat32Array h;
	h.resize(n);
	float *hw = h.ptrw();
	std::vector<uint8_t> was_cut(n, 0);
	Pasture3DThreadPool::parallel_for_elements(n, 4096, [&](int b, int e) {
		for (int i = b; i < e; i++) {
			double v = h0[i];
			if (lm[i] > 0.5f) {
				const double R = P.retreat * exposure_at(i);
				const double d = d_sea[i];
				if (R > 0.0 && d < R) {
					const double plat = P.sea_level - P.platform_depth * (1.0 - d / R);
					if (plat < v) {
						v = plat;
						was_cut[i] = 1;
					}
				}
			}
			hw[i] = (float)v;
		}
	});

	// 3. Cliff face: talus relaxation over the cut band, its one-cell rim and the crest. Mask 1 where it may move.
	if (P.cliff_iterations > 0) {
		PackedFloat32Array band;
		band.resize(n);
		float *bw = band.ptrw();
		bool any = false;
		for (int iz = 0; iz < p_gh; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				bool near_cut = false;
				for (int oz = -1; oz <= 1 && !near_cut; oz++) {
					for (int ox = -1; ox <= 1; ox++) {
						const int jx = ix + ox, jz = iz + oz;
						if (jx >= 0 && jz >= 0 && jx < p_gw && jz < p_gh && was_cut[jz * p_gw + jx]) {
							near_cut = true;
							break;
						}
					}
				}
				bw[iz * p_gw + ix] = near_cut ? 1.f : 0.f;
				any = any || near_cut;
			}
		}
		// Crest rounding: land within crest_reach of a cut joins the band, by the shared JFA transform.
		if (any && P.crest_reach > 0.0) {
			PackedFloat32Array cut_mask;
			cut_mask.resize(n);
			float *cm = cut_mask.ptrw();
			for (int i = 0; i < n; i++) cm[i] = was_cut[i] ? 1.f : 0.f;
			const PackedFloat32Array d_cut = distance_transform_solve(cut_mask, p_gw, p_gh, p_rect, 0.5,
					DISTANCE_TRANSFORM_OUTSIDE, DISTANCE_TRANSFORM_EUCLIDEAN, DISTANCE_TRANSFORM_METRES, 0.0, nullptr);
			if (d_cut.size() == n) {
				const float *dc = d_cut.ptr();
				for (int i = 0; i < n; i++) {
					if (lm[i] > 0.5f && (double)dc[i] <= P.crest_reach) bw[i] = 1.f;
				}
			}
		}
		// The repose angle per cell. Equal angles take the scalar path, bit-identical to before.
		std::vector<float> tans;
		if (any && P.slack_angle != P.cliff_angle) {
			tans.resize(n);
			const double d2r = 3.14159265358979323846 / 180.0;
			for (int i = 0; i < n; i++) {
				const double e = exposure_at(i);
				tans[i] = (float)std::tan((P.slack_angle + (P.cliff_angle - P.slack_angle) * e) * d2r);
			}
		}
		if (any) {
			const PackedFloat32Array relaxed = talus_projection_solve(h, band, p_gw, p_gh, p_rect, P.cliff_angle,
					P.cliff_iterations, 0.5, 1.0, tans.empty() ? nullptr : tans.data());
			if (relaxed.size() == n) {
				h = relaxed;
				hw = h.ptrw();
			}
		}
	}

	// 4. Beaches where the sea is sheltered. Raise only.
	PackedFloat32Array cut, dep;
	cut.resize(n);
	dep.resize(n);
	float *cw = cut.ptrw();
	float *dw = dep.ptrw();
	Pasture3DThreadPool::parallel_for_elements(n, 4096, [&](int b, int e) {
		for (int i = b; i < e; i++) {
			if (!std::isfinite(h0[i])) {
				hw[i] = h0[i];
				cw[i] = 0.f;
				dw[i] = 0.f;
				continue;
			}
			const double after_cut = hw[i];
			double v = after_cut;
			if (P.beach_width > 0.0 && P.deposit > 0.0) {
				const double s = lm[i] > 0.5f ? (double)d_sea[i] : (wm[i] > 0.5f ? -(double)d_land[i] : 1e30);
				if (s >= -0.5 * P.beach_width && s <= P.beach_width) {
					const double target = P.sea_level + P.beach_height * s / P.beach_width;
					if (target > v) {
						v += (target - v) * P.deposit * (1.0 - exposure_at(i));
					}
				}
			}
			hw[i] = (float)v;
			cw[i] = (float)std::max((double)h0[i] - after_cut, 0.0);
			dw[i] = (float)std::max(v - after_cut, 0.0);
		}
	});

	out["height"] = h;
	out["cut"] = cut;
	out["deposit"] = dep;
	return out;
}
