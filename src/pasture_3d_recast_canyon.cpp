// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_recast_canyon.h"
#include "pasture_3d_thread_pool.h"

#include <algorithm>
#include <cmath>

using namespace godot;

PackedFloat32Array godot::recast_canyon_solve(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_noise,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh, double p_cut_height, double p_floor_height,
		double p_gamma, double p_amount) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	if (p_gw <= 0 || p_gh <= 0 || p_surface.size() != n) {
		return out;
	}
	out.resize(n);
	const float *src = p_surface.ptr();
	if (p_amount <= 0.0 || p_gamma <= 0.0) {
		std::copy_n(src, n, out.ptrw());
		return out;
	}
	const float *nz = (p_noise.size() == n) ? p_noise.ptr() : nullptr;
	const float *mk = (p_mask.size() == n) ? p_mask.ptr() : nullptr;
	const double amount = std::min(p_amount, 1.0);
	float *dst = out.ptrw();

	Pasture3DThreadPool::parallel_for_rows(p_gh, 64, [&](int z0, int z1) {
		for (int i = z0 * p_gw; i < z1 * p_gw; i++) {
			const double z = (double)src[i];
			if (!std::isfinite(z)) {
				dst[i] = (float)z;
				continue;
			}
			double cut = p_cut_height;
			if (nz != nullptr && std::isfinite(nz[i])) {
				cut += (double)nz[i];
			}
			const double span = cut - p_floor_height;
			if (span <= 1.0e-6 || z >= cut || z <= p_floor_height) {
				dst[i] = (float)z;
				continue;
			}
			double w = amount;
			if (mk != nullptr) {
				const double m = (double)mk[i];
				w *= std::isfinite(m) ? std::clamp(m, 0.0, 1.0) : 0.0;
			}
			if (w <= 0.0) {
				dst[i] = (float)z;
				continue;
			}
			const double t = (z - p_floor_height) / span;
			const double recast = p_floor_height + span * std::pow(t, p_gamma);
			dst[i] = (float)(z + (recast - z) * w);
		}
	});
	return out;
}
