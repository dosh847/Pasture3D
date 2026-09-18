// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_strata.h"
#include "pasture_3d_graph_ops.h"
#include "pasture_3d_thread_pool.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <algorithm>
#include <cmath>

using namespace godot;

PackedFloat32Array godot::strata_grid(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_band_height, double p_hardness,
		double p_amount, double p_dip, double p_dip_direction_deg,
		double p_break_amount, double p_break_size, int p_seed, const PackedFloat32Array &p_profile_lut,
		int p_profile_mode, double p_hardness_variation, int p_octaves, double p_lacunarity) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	out.resize(n);
	if (n <= 0 || p_surface.size() != n) {
		return out;
	}

	if (std::abs(p_amount) <= 1e-7) {
		return p_surface.duplicate();
	}

	Ref<FastNoiseLite> nz;
	// One noise field drives both the boundary wander and the hardness variation.
	const double variation = std::clamp(p_hardness_variation, 0.0, 1.0);
	if (p_break_amount > 0.0 || variation > 0.0) {
		nz.instantiate();
		nz->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
		nz->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
		nz->set_fractal_octaves(3);
		nz->set_frequency((real_t)(1.0 / std::max(p_break_size, 0.01)));
		nz->set_seed(p_seed);
	}

	const float *s_ptr = p_surface.ptr();
	float *w = out.ptrw();
	const int lut_n = p_profile_lut.size();
	const float *lut_ptr = p_profile_lut.ptr();

	const double dipdir = p_dip_direction_deg * (Math_PI / 180.0);
	const double cos_dip = std::cos(dipdir);
	const double sin_dip = std::sin(dipdir);
	const double bh = std::max(p_band_height, 0.001);
	const double gamma = strata_hardness_to_gamma(p_hardness);
	const int octaves = std::clamp(p_octaves, 1, 8);
	const double lacunarity = std::max(p_lacunarity, 1.0);

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = row + ix;
				const float x = s_ptr[i];
				if (std::isnan(x)) {
					w[i] = NAN;
					continue;
				}

				double wx, wz;
				graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, wx, wz);

				const double dip_tilt = p_dip * (wx * cos_dip + wz * sin_dip) * 0.01;
				double nv = 0.0;
				double g = gamma;
				if (nz.is_valid()) {
					nv = (double)nz->get_noise_2d((real_t)wx, (real_t)wz);
					g = strata_local_gamma(gamma, variation, nv);
				}

				// Octave k bands the OUTPUT of octave k-1 at band_height / lacunarity^k, so beds sit inside beds.
				// The dip is shared; the lateral wander shrinks with the bed, so fine beds wander proportionally
				// as much as coarse ones.
				double val = (double)x;
				double scale = 1.0;
				for (int k = 0; k < octaves; k++) {
					const double bh_k = bh / scale;
					const double tilt = dip_tilt + nv * p_break_amount / scale;
					const double t = (val + tilt) / bh_k;
					const double q = std::floor(t);
					const double f = t - q;

					// A custom profile is the lowered LUT, sampled as every graph LUT is (clamp, lower index capped
					// at n - 2, linear); the GPU's p3d_lut is its twin. Shorter than 2 = the built-in profile.
					double profile_val;
					if (lut_n >= 2) {
						const double f_idx = std::clamp(f, 0.0, 1.0) * (double)(lut_n - 1);
						const int i0 = std::min((int)f_idx, lut_n - 2);
						const double frac = f_idx - (double)i0;
						profile_val = (double)lut_ptr[i0] * (1.0 - frac) + (double)lut_ptr[i0 + 1] * frac;
					} else {
						profile_val = strata_profile(p_profile_mode, f, g);
					}
					// The tilt only chooses WHERE the beds fall; it comes back off, or the dip would tilt the
					// ground itself.
					val = (q + profile_val) * bh_k - tilt;
					scale *= lacunarity;
				}
				const double stepped = val;

				w[i] = (float)((double)x + ((stepped - (double)x) * p_amount));
			}
		}
	});

	return out;
}
