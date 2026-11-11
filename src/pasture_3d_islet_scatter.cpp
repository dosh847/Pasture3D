// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Islet Scatter kernel. The model is in pasture_3d_islet_scatter.h.

#include "pasture_3d_islet_scatter.h"
#include "pasture_3d_distance_transform.h"
#include "pasture_3d_geo_primitives.h"
#include "pasture_3d_thread_pool.h"

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>
#include <unordered_map>
#include <vector>

using namespace godot;

IsletScatterParams godot::islet_scatter_params_from(const float *p_params, int p_count) {
	IsletScatterParams r;
	auto at = [&](int i, double d) -> double { return (p_params && i < p_count) ? (double)p_params[i] : d; };
	r.sea_level = at(0, r.sea_level);
	r.seed = (int)std::lround(at(1, r.seed));
	r.spacing = std::max(at(2, r.spacing), 1.0);
	r.density = std::clamp(at(3, r.density), 0.0, 1.0);
	r.min_offshore = std::max(at(4, r.min_offshore), 0.0);
	r.max_offshore = std::max(at(5, r.max_offshore), r.min_offshore);
	r.radius_min = std::max(at(6, r.radius_min), 0.1);
	r.radius_max = std::max(at(7, r.radius_max), r.radius_min);
	r.height_min = at(8, r.height_min);
	r.height_max = std::max(at(9, r.height_max), r.height_min);
	r.base_depth = std::max(at(10, r.base_depth), 0.0);
	r.roughness = std::clamp(at(11, r.roughness), 0.0, 1.0);
	r.stack_fraction = std::clamp(at(12, r.stack_fraction), 0.0, 1.0);
	return r;
}

namespace {

struct Islet {
	double x = 0.0, z = 0.0, r = 1.0, top = 0.0;
	bool stack = false;
	double phase[3] = { 0.0, 0.0, 0.0 };
};

// A uniform draw in [0, 1) from lattice cell (i, j), the seed and a stream index.
double draw(int p_i, int p_j, int p_seed, uint32_t p_k) {
	uint32_t s = wang_hash((uint32_t)p_i * 73856093u ^ (uint32_t)p_j * 19349663u ^ (uint32_t)p_seed * 83492791u);
	s = wang_hash(s ^ (p_k * 0x9e3779b9u));
	return (double)(s >> 8) * (1.0 / 16777216.0);
}

int64_t key(int p_i, int p_j) {
	return ((int64_t)p_i << 32) ^ (int64_t)(uint32_t)p_j;
}

} // namespace

Dictionary godot::islet_scatter_grid(const PackedFloat32Array &p_height, const PackedFloat32Array &p_exposure,
		int p_gw, int p_gh, const Rect2 &p_rect, const IsletScatterParams &p_prm) {
	Dictionary out;
	const int n = p_gw * p_gh;
	if (p_gw <= 0 || p_gh <= 0 || p_height.size() != n) {
		return out;
	}
	const IsletScatterParams P = p_prm;
	const float *h0 = p_height.ptr();
	const float *ex = p_exposure.size() == n ? p_exposure.ptr() : nullptr;
	const double cdx = p_rect.size.x / p_gw, cdz = p_rect.size.y / p_gh;

	// Distance from water to the nearest land, metres, by the shared JFA transform.
	PackedFloat32Array land_mask;
	land_mask.resize(n);
	{
		float *lmw = land_mask.ptrw();
		for (int i = 0; i < n; i++) {
			lmw[i] = (std::isfinite(h0[i]) && (double)h0[i] >= P.sea_level) ? 1.f : 0.f;
		}
	}
	const PackedFloat32Array d_land_arr = distance_transform_solve(land_mask, p_gw, p_gh, p_rect, 0.5,
			DISTANCE_TRANSFORM_OUTSIDE, DISTANCE_TRANSFORM_EUCLIDEAN, DISTANCE_TRANSFORM_METRES, 0.0, nullptr);
	if (d_land_arr.size() != n) {
		return out;
	}
	const float *d_land = d_land_arr.ptr();
	const float *lm = land_mask.ptr();

	// Candidates: one per lattice cell whose jittered centre falls on a water cell of the grid.
	const double S = P.spacing;
	const int i0 = (int)std::floor(p_rect.position.x / S);
	const int i1 = (int)std::floor((p_rect.position.x + p_rect.size.x) / S);
	const int j0 = (int)std::floor(p_rect.position.y / S);
	const int j1 = (int)std::floor((p_rect.position.y + p_rect.size.y) / S);
	std::unordered_map<int64_t, Islet> islets;
	double reach = 0.0;
	if (P.density > 0.0) {
		for (int j = j0; j <= j1; j++) {
			for (int i = i0; i <= i1; i++) {
				if (draw(i, j, P.seed, 0) >= P.density) continue;
				const double x = (i + draw(i, j, P.seed, 1)) * S;
				const double z = (j + draw(i, j, P.seed, 2)) * S;
				const int cx = (int)std::floor((x - p_rect.position.x) / cdx);
				const int cz = (int)std::floor((z - p_rect.position.y) / cdz);
				if (cx < 0 || cz < 0 || cx >= p_gw || cz >= p_gh) continue;
				const int c = cz * p_gw + cx;
				if (!std::isfinite(h0[c]) || lm[c] > 0.5f) continue;
				const double d = d_land[c];
				if (d < P.min_offshore || d > P.max_offshore) continue;
				double e = 1.0;
				if (ex) e = std::isfinite(ex[c]) ? std::clamp((double)ex[c], 0.0, 1.0) : 0.0;
				Islet it;
				it.x = x;
				it.z = z;
				it.stack = draw(i, j, P.seed, 3) < P.stack_fraction * e;
				it.r = P.radius_min + (P.radius_max - P.radius_min) * draw(i, j, P.seed, 4);
				double hgt = P.height_min + (P.height_max - P.height_min) * draw(i, j, P.seed, 5);
				if (it.stack) {
					it.r *= 0.4;
					hgt *= 1.5;
				}
				it.top = hgt;
				for (int k = 0; k < 3; k++) it.phase[k] = draw(i, j, P.seed, 6 + k) * 6.283185307179586;
				reach = std::max(reach, it.r * (1.0 + P.roughness));
				islets[key(i, j)] = it;
			}
		}
	}

	PackedFloat32Array h, isl, stk;
	h.resize(n);
	isl.resize(n);
	stk.resize(n);
	float *hw = h.ptrw();
	float *iw = isl.ptrw();
	float *sw = stk.ptrw();
	const int span = (int)std::ceil(reach / S) + 1;
	Pasture3DThreadPool::parallel_for_rows(p_gh, 8, [&](int r0, int r1) {
		for (int iz = r0; iz < r1; iz++) {
			const double wz = p_rect.position.y + (iz + 0.5) * cdz;
			for (int ix = 0; ix < p_gw; ix++) {
				const int c = iz * p_gw + ix;
				hw[c] = h0[c];
				iw[c] = 0.f;
				sw[c] = 0.f;
				if (!std::isfinite(h0[c]) || islets.empty()) continue;
				const double wx = p_rect.position.x + (ix + 0.5) * cdx;
				const int ci = (int)std::floor(wx / S), cj = (int)std::floor(wz / S);
				double v = h0[c];
				for (int j = cj - span; j <= cj + span; j++) {
					for (int i = ci - span; i <= ci + span; i++) {
						auto f = islets.find(key(i, j));
						if (f == islets.end()) continue;
						const Islet &it = f->second;
						const double ox = wx - it.x, oz = wz - it.z;
						const double dist = std::sqrt(ox * ox + oz * oz);
						if (dist >= it.r * (1.0 + P.roughness)) continue;
						const double a = std::atan2(oz, ox);
						const double wob = std::sin(2.0 * a + it.phase[0]) * 0.5 + std::sin(3.0 * a + it.phase[1]) * 0.3 +
								std::sin(5.0 * a + it.phase[2]) * 0.2;
						const double rr = it.r * (1.0 + P.roughness * wob);
						const double t = dist / std::max(rr, 1e-6);
						if (t >= 1.0) continue;
						double shape;
						if (it.stack) {
							const double s = std::clamp((1.0 - t) / 0.25, 0.0, 1.0);
							shape = s * s * (3.0 - 2.0 * s);
						} else {
							shape = std::pow(1.0 - t * t, 0.75);
						}
						const double z = P.sea_level - P.base_depth + (it.top + P.base_depth) * shape;
						if (z > v) v = z;
						if (z > P.sea_level) (it.stack ? sw[c] : iw[c]) = 1.f;
					}
				}
				hw[c] = (float)v;
			}
		}
	});

	out["height"] = h;
	out["islets"] = isl;
	out["stacks"] = stk;
	return out;
}
