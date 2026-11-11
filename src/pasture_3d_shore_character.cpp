// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Shore Character kernel. The model is in pasture_3d_shore_character.h. It reuses box_mean_solve for both
// window means and fractal_grid for the hardness noise; it adds no blur or noise of its own.

#include "pasture_3d_shore_character.h"
#include "pasture_3d_distance_transform.h"
#include "pasture_3d_fractal.h"
#include "pasture_3d_terrain_metrics.h"
#include "pasture_3d_thread_pool.h"

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>
#include <vector>

using namespace godot;

ShoreCharacterParams godot::shore_character_params_from(const float *p_params, int p_count) {
	ShoreCharacterParams r;
	auto at = [&](int i, double d) -> double { return (p_params && i < p_count) ? (double)p_params[i] : d; };
	r.sea_level = at(0, r.sea_level);
	r.seed = (int)std::lround(at(1, r.seed));
	r.bay_radius = std::max(at(2, r.bay_radius), 0.0);
	r.cove_radius = std::max(at(3, r.cove_radius), 0.0);
	r.shape_weight = std::max(at(4, r.shape_weight), 0.0);
	r.exposure_weight = std::max(at(5, r.exposure_weight), 0.0);
	r.backshore_weight = std::max(at(6, r.backshore_weight), 0.0);
	r.backshore_dist = std::max(at(7, r.backshore_dist), 0.0);
	r.backshore_height = std::max(at(8, r.backshore_height), 1e-3);
	r.threshold = std::clamp(at(9, r.threshold), 0.0, 1.0);
	r.softness = std::max(at(10, r.softness), 1e-3);
	r.hardness_scale = std::max(at(11, r.hardness_scale), 1.0);
	r.hardness_variation = std::clamp(at(12, r.hardness_variation), 0.0, 1.0);
	r.carry_reach = std::max(at(13, r.carry_reach), 0.0);
	r.carry_smooth = std::max(at(14, r.carry_smooth), 0.0);
	return r;
}

namespace {

double ss(double x) {
	const double t = std::clamp(x, 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

} // namespace

Dictionary godot::shore_character_grid(const PackedFloat32Array &p_height, const PackedFloat32Array &p_exposure,
		int p_gw, int p_gh, const Rect2 &p_rect, const ShoreCharacterParams &p_prm) {
	Dictionary out;
	const int n = p_gw * p_gh;
	if (p_gw <= 0 || p_gh <= 0 || p_height.size() != n) {
		return out;
	}
	const ShoreCharacterParams P = p_prm;
	const float *h0 = p_height.ptr();
	const float *ex = p_exposure.size() == n ? p_exposure.ptr() : nullptr;

	// Land fraction and land-only height above sea. A NaN cell is neither: NaN in both, so the shared box
	// mean skips it.
	PackedFloat32Array land, above;
	land.resize(n);
	above.resize(n);
	{
		float *lw = land.ptrw();
		float *aw = above.ptrw();
		for (int i = 0; i < n; i++) {
			if (!std::isfinite(h0[i])) {
				lw[i] = NAN;
				aw[i] = NAN;
				continue;
			}
			const bool is_land = (double)h0[i] >= P.sea_level;
			lw[i] = is_land ? 1.f : 0.f;
			aw[i] = is_land ? (float)((double)h0[i] - P.sea_level) : 0.f;
		}
	}

	const PackedFloat32Array f_bay = box_mean_solve(land, p_gw, p_gh, p_rect, P.bay_radius);
	const PackedFloat32Array f_cove = box_mean_solve(land, p_gw, p_gh, p_rect, P.cove_radius);
	const PackedFloat32Array back_h = box_mean_solve(above, p_gw, p_gh, p_rect, P.backshore_dist);
	const PackedFloat32Array back_f = box_mean_solve(land, p_gw, p_gh, p_rect, P.backshore_dist);
	PackedFloat32Array noise;
	if (P.hardness_variation > 0.0) {
		noise = fractal_grid(p_gw, p_gh, p_rect, FRACTAL_STYLE_HILLS, 1.0, P.hardness_scale, 3, 2.0, 0.5, 1.0,
				P.seed, 0.0, 1.0, 1);
	}
	if (f_bay.size() != n || f_cove.size() != n || back_h.size() != n || back_f.size() != n) {
		return out;
	}
	const float *fb = f_bay.ptr();
	const float *fc = f_cove.ptr();
	const float *bh = back_h.ptr();
	const float *bf = back_f.ptr();
	const float *nz = noise.size() == n ? noise.ptr() : nullptr;
	const double wsum = P.shape_weight + P.exposure_weight + P.backshore_weight;

	PackedFloat32Array cliff, beach, hard, ero;
	cliff.resize(n);
	beach.resize(n);
	hard.resize(n);
	ero.resize(n);
	float *cw = cliff.ptrw();
	float *bw = beach.ptrw();
	float *hw = hard.ptrw();
	float *ew = ero.ptrw();

	// The weighted score per cell, before the threshold.
	std::vector<double> raw((size_t)n, 1.0);
	std::vector<double> expo((size_t)n, 1.0);
	Pasture3DThreadPool::parallel_for_elements(n, 4096, [&](int b, int e) {
		for (int i = b; i < e; i++) {
			double exposure = 1.0;
			if (ex) exposure = std::isfinite(ex[i]) ? std::clamp((double)ex[i], 0.0, 1.0) : 0.0;
			const double fbi = std::isfinite(fb[i]) ? (double)fb[i] : 0.0;
			const double fci = std::isfinite(fc[i]) ? (double)fc[i] : 0.0;
			const double shape = ss(1.0 - 0.5 * (fbi + fci)); // enclosed by land = bay = beach
			const double frac = std::isfinite(bf[i]) ? (double)bf[i] : 0.0;
			const double mean_h = (frac > 1e-6 && std::isfinite(bh[i])) ? (double)bh[i] / frac : 0.0;
			const double back = std::clamp(mean_h / P.backshore_height, 0.0, 1.0);
			expo[(size_t)i] = exposure;
			if (wsum > 0.0) {
				raw[(size_t)i] = (P.shape_weight * shape + P.exposure_weight * exposure + P.backshore_weight * back) / wsum;
			}
		}
	});

	// Carry the shoreline's score inland. Shore = finite land with a 4-neighbour finite water cell.
	if (P.carry_reach > 0.0 && wsum > 0.0) {
		const float *lw = land.ptr();
		PackedFloat32Array shore;
		shore.resize(n);
		float *sw = shore.ptrw();
		for (int iz = 0; iz < p_gh; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = iz * p_gw + ix;
				bool s = false;
				if (lw[i] == 1.f) {
					const int nb[4][2] = { { ix - 1, iz }, { ix + 1, iz }, { ix, iz - 1 }, { ix, iz + 1 } };
					for (const auto &q : nb) {
						if (q[0] >= 0 && q[1] >= 0 && q[0] < p_gw && q[1] < p_gh && lw[q[1] * p_gw + q[0]] == 0.f) {
							s = true;
							break;
						}
					}
				}
				sw[i] = s ? 1.f : 0.f;
			}
		}
		PackedFloat32Array dist;
		const PackedInt32Array near = distance_transform_nearest(shore, p_gw, p_gh, p_rect, 0.5, &dist);
		if (near.size() == n && dist.size() == n) {
			const int32_t *nr = near.ptr();
			const float *dd = dist.ptr();
			std::vector<double> carried(raw);
			for (int i = 0; i < n; i++) {
				if (lw[i] == 1.f && nr[i] >= 0 && (double)dd[i] <= P.carry_reach) {
					carried[(size_t)i] = raw[(size_t)nr[i]];
				}
			}
			raw.swap(carried);
			// Smooth the seams over land only: water is NaN, which the box mean skips.
			if (P.carry_smooth > 0.0) {
				PackedFloat32Array lr;
				lr.resize(n);
				float *lrw = lr.ptrw();
				for (int i = 0; i < n; i++) lrw[i] = lw[i] == 1.f ? (float)raw[(size_t)i] : NAN;
				const PackedFloat32Array sm = box_mean_solve(lr, p_gw, p_gh, p_rect, P.carry_smooth);
				if (sm.size() == n) {
					const float *smr = sm.ptr();
					for (int i = 0; i < n; i++) {
						if (lw[i] == 1.f && std::isfinite(smr[i])) raw[(size_t)i] = (double)smr[i];
					}
				}
			}
		}
	}

	Pasture3DThreadPool::parallel_for_elements(n, 4096, [&](int b, int e) {
		for (int i = b; i < e; i++) {
			const double exposure = expo[(size_t)i];
			const double c = wsum > 0.0 ? ss((raw[(size_t)i] - P.threshold) / P.softness + 0.5) : 1.0;
			const double nv = nz ? (double)nz[i] : 0.0;
			const double hd = std::clamp(0.5 + 0.5 * P.hardness_variation * nv, 0.0, 1.0);
			cw[i] = (float)c;
			bw[i] = (float)(1.0 - c);
			hw[i] = (float)hd;
			ew[i] = (float)(exposure * (1.0 - hd));
		}
	});

	out["cliff"] = cliff;
	out["beach"] = beach;
	out["hardness"] = hard;
	out["erosion"] = ero;
	return out;
}
