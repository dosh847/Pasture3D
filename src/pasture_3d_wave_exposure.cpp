// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Wave Exposure kernel. See pasture_3d_wave_exposure.h for the recurrence and why it is one sweep per
// direction. Serial over directions: each sweep is O(N) with a row-to-row dependency, and K is small.

#include "pasture_3d_wave_exposure.h"

#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>
#include <vector>

using namespace godot;

WaveExposureParams godot::wave_exposure_params_from(const float *p_params, int p_count) {
	WaveExposureParams r;
	auto at = [&](int i, double d) -> double { return (p_params && i < p_count) ? (double)p_params[i] : d; };
	r.sea_level = at(0, r.sea_level);
	r.max_fetch = std::max(at(1, r.max_fetch), 1e-3);
	r.directions = std::clamp((int)std::lround(at(2, r.directions)), 1, 256);
	r.wind_direction = at(3, r.wind_direction);
	r.wind_strength = std::clamp(at(4, r.wind_strength), 0.0, 1.0);
	r.shore_reach = std::max(at(5, r.shore_reach), 0.0);
	r.edge_open = at(6, 1.0) > 0.5;
	return r;
}

Dictionary godot::wave_exposure_grid(const PackedFloat32Array &p_height, int p_gw, int p_gh, const Rect2 &p_rect,
		const WaveExposureParams &p_prm) {
	Dictionary out;
	if (p_gw <= 0 || p_gh <= 0 || p_height.size() != p_gw * p_gh) {
		return out;
	}
	const int n = p_gw * p_gh;
	const WaveExposureParams P = p_prm;
	const double dx = p_rect.size.x / (double)p_gw;
	const double dz = p_rect.size.y / (double)p_gh;
	const double edge = P.edge_open ? P.max_fetch : 0.0;

	const float *h = p_height.ptr();
	std::vector<uint8_t> water(n);
	for (int i = 0; i < n; i++) {
		water[i] = (std::isfinite(h[i]) && (double)h[i] < P.sea_level) ? 1 : 0;
	}

	std::vector<double> sum_e(n, 0.0), sum_f(n, 0.0);
	std::vector<float> F(n), A(n), D(n);
	double sum_w = 0.0;
	const double wind = P.wind_direction * (Math_PI / 180.0);

	for (int k = 0; k < P.directions; k++) {
		// Direction k is a compass bearing the waves come FROM. Direction 0 IS the wind, so a wind on an axis
		// gives exact axis sweeps whenever the count is a multiple of four.
		const double a = wind + Math_TAU * (double)k / (double)P.directions;
		const double c = std::cos(a - wind);
		const double w = (1.0 - P.wind_strength) + P.wind_strength * std::pow(std::max(c, 0.0), 2.0);
		if (w <= 0.0) {
			continue;
		}
		sum_w += w;
		// Upwind unit vector in grid space (x, z). North is -Z.
		double ux = std::sin(a);
		double uz = -std::cos(a);
		if (std::abs(ux) < 1e-12) ux = 0.0;
		if (std::abs(uz) < 1e-12) uz = 0.0;
		const double m = std::max(std::abs(ux), std::abs(uz));
		const double sx = ux / m;
		const double sz = uz / m;
		const double L = std::sqrt(sx * dx * sx * dx + sz * dz * sz * dz);

		// Bilinear read at the predecessor of (ix, iz). `r_off` is set when any tap is off the grid.
		auto pred = [&](const std::vector<float> &arr, int ix, int iz, bool &r_off) -> double {
			const double px = (double)ix + sx;
			const double pz = (double)iz + sz;
			const int x0 = (int)std::floor(px);
			const int z0 = (int)std::floor(pz);
			const double fx = px - (double)x0;
			const double fz = pz - (double)z0;
			const int x1 = fx > 1e-9 ? x0 + 1 : x0;
			const int z1 = fz > 1e-9 ? z0 + 1 : z0;
			if (x0 < 0 || z0 < 0 || x1 >= p_gw || z1 >= p_gh) {
				r_off = true;
				return 0.0;
			}
			r_off = false;
			const double a00 = arr[z0 * p_gw + x0], a10 = arr[z0 * p_gw + x1];
			const double a01 = arr[z1 * p_gw + x0], a11 = arr[z1 * p_gw + x1];
			return (a00 * (1.0 - fx) + a10 * fx) * (1.0 - fz) + (a01 * (1.0 - fx) + a11 * fx) * fz;
		};

		// Visit order puts the predecessor first: sz > 0 reads row iz+1, so rows run bottom to top; sx > 0
		// reads column ix+1, so columns run right to left.
		const bool z_desc = sz > 0.0;
		const bool x_desc = sx > 0.0;
		for (int zi = 0; zi < p_gh; zi++) {
			const int iz = z_desc ? p_gh - 1 - zi : zi;
			for (int xi = 0; xi < p_gw; xi++) {
				const int ix = x_desc ? p_gw - 1 - xi : xi;
				const int i = iz * p_gw + ix;
				bool off = false;
				if (water[i]) {
					const double f = pred(F, ix, iz, off);
					F[i] = (float)std::min(L + (off ? edge : f), P.max_fetch);
					A[i] = F[i];
					D[i] = 0.f;
				} else {
					const double carried = pred(A, ix, iz, off);
					bool off_d = false;
					const double d_prev = pred(D, ix, iz, off_d);
					F[i] = 0.f;
					A[i] = (float)(off ? edge : carried);
					D[i] = (float)std::min(L + (off_d ? 0.0 : d_prev), P.shore_reach + 2.0 * L);
				}
				// Land fades over shore_reach metres counted from its first cell, whatever the step length.
				double e = A[i];
				if (!water[i]) {
					const double into = (double)D[i] - L;
					e *= P.shore_reach > 0.0 ? std::clamp(1.0 - into / P.shore_reach, 0.0, 1.0)
											 : (into <= 1e-6 ? 1.0 : 0.0);
				}
				sum_e[i] += w * e / P.max_fetch;
				sum_f[i] += w * e;
			}
		}
	}

	PackedFloat32Array exposure, fetch;
	exposure.resize(n);
	fetch.resize(n);
	float *we = exposure.ptrw();
	float *wf = fetch.ptrw();
	const double inv = sum_w > 0.0 ? 1.0 / sum_w : 0.0;
	for (int i = 0; i < n; i++) {
		we[i] = (float)std::clamp(sum_e[i] * inv, 0.0, 1.0);
		wf[i] = (float)(sum_f[i] * inv);
	}
	out["exposure"] = exposure;
	out["fetch"] = fetch;
	return out;
}
