// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_displace.h"
#include "pasture_3d_thread_pool.h"
#include "pasture_3d_transform.h"

#include <algorithm>
#include <cmath>

using namespace godot;

// The SAME epsilon as GRADIENT_EPSILON in pasture_3d_warp_downslope.cpp: below it the uphill direction is
// numerical noise.
static constexpr double SLOPE_EPSILON = 1.0e-4;

PackedFloat32Array godot::displace_solve(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_dx,
		const PackedFloat32Array &p_dy, const PackedFloat32Array &p_mask, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_scale, double p_amount, int p_direction) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	if (p_gw <= 0 || p_gh <= 0 || p_surface.size() != n) {
		return out;
	}
	out.resize(n);

	const float *src = p_surface.ptr();
	const float *ox_f = (p_dx.size() == n) ? p_dx.ptr() : nullptr;
	const float *oz_f = (p_dy.size() == n) ? p_dy.ptr() : nullptr;
	if (p_amount <= 0.0 || p_scale == 0.0 || (ox_f == nullptr && oz_f == nullptr)) {
		std::copy_n(src, n, out.ptrw());
		return out;
	}
	const float *mk = (p_mask.size() == n) ? p_mask.ptr() : nullptr;

	const double dx = (double)p_rect.size.x / (double)p_gw;
	const double dz = (double)p_rect.size.y / (double)p_gh;
	const double amount = std::min(p_amount, 1.0);
	float *dst = out.ptrw();

	// A cell reads the source and the operands and never `dst`, so the rows split exactly.
	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = iz * p_gw + ix;
				const double z = (double)src[i];
				if (!std::isfinite(z)) {
					dst[i] = (float)z; // NaN is the brush-loop mask; it stays put and stays NaN.
					continue;
				}
				double w = amount;
				if (mk != nullptr) {
					const double m = (double)mk[i];
					w *= std::isfinite(m) ? std::clamp(m, 0.0, 1.0) : 0.0;
				}
				double ux = ox_f ? (double)ox_f[i] : 0.0;
				double uz = oz_f ? (double)oz_f[i] : 0.0;
				if (w <= 0.0 || !std::isfinite(ux) || !std::isfinite(uz)) {
					dst[i] = (float)z;
					continue;
				}
				if (p_direction == 1) {
					// SLOPE: rotate the offset into the surface's frame. Central differences, one-sided at
					// the edge -- the stencil Warp Downslope uses.
					const int xm = std::max(ix - 1, 0), xp = std::min(ix + 1, p_gw - 1);
					const int zm = std::max(iz - 1, 0), zp = std::min(iz + 1, p_gh - 1);
					const double sxm = src[iz * p_gw + xm], sxp = src[iz * p_gw + xp];
					const double szm = src[zm * p_gw + ix], szp = src[zp * p_gw + ix];
					if (!std::isfinite(sxm) || !std::isfinite(sxp) || !std::isfinite(szm) || !std::isfinite(szp)) {
						dst[i] = (float)z;
						continue;
					}
					const double gx = (xp > xm) ? (sxp - sxm) / ((double)(xp - xm) * dx) : 0.0;
					const double gz = (zp > zm) ? (szp - szm) / ((double)(zp - zm) * dz) : 0.0;
					const double mag = std::sqrt(gx * gx + gz * gz);
					if (mag <= SLOPE_EPSILON) {
						dst[i] = (float)z;
						continue;
					}
					const double tx = gx / mag, tz = gz / mag;
					// Reading UPHILL brings higher ground down onto this cell: the slope moves outward.
					const double along = ux, across = uz;
					ux = along * tx - across * tz;
					uz = along * tz + across * tx;
				}
				// The offset is METRES, converted to cells for the tap. Offsetting in cells would make the
				// same dx field push further every time the bake resolution rose.
				const double fx = (double)ix + ux * p_scale * w / dx;
				const double fz = (double)iz + uz * p_scale * w / dz;
				dst[i] = (float)transform_sample_bilinear(src, fx, fz, p_gw, p_gh, TRANSFORM_EDGE_CLAMP);
			}
		}
	});
	return out;
}
