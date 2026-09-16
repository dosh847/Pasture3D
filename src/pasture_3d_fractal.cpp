// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_fractal.h"
#include "pasture_3d_graph_ops.h"
#include "pasture_3d_thread_pool.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <algorithm>
#include <cmath>

using namespace godot;

namespace {

// Pasture3DReliefMaterial._configure_noise, to the setter.
Ref<FastNoiseLite> configure_noise(double p_freq, int p_octaves, double p_lacunarity, double p_gain,
		int p_seed, bool p_ridged) {
	Ref<FastNoiseLite> n;
	n.instantiate();
	n->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
	n->set_seed(p_seed);
	n->set_frequency((real_t)std::max(p_freq, 0.000001));
	n->set_fractal_type(p_ridged ? FastNoiseLite::FRACTAL_RIDGED : FastNoiseLite::FRACTAL_FBM);
	n->set_fractal_octaves(std::clamp(p_octaves, 1, 8));
	n->set_fractal_lacunarity((real_t)p_lacunarity);
	n->set_fractal_gain((real_t)p_gain);
	n->set_fractal_weighted_strength(0.0f);
	return n;
}

} // namespace

PackedFloat32Array godot::fractal_grid(int p_gw, int p_gh, const Rect2 &p_rect,
		int p_style, double p_amplitude, double p_feature_size, int p_octaves,
		double p_lacunarity, double p_gain, double p_sharpness, int p_seed,
		double p_warp_amount, double p_warp_size, int p_warp_octaves) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	out.resize(std::max(n, 0));
	if (n <= 0) {
		return out;
	}
	if (std::abs(p_amplitude) <= 1e-7) {
		out.fill(0.f);
		return out;
	}

	const bool ridged = (p_style == FRACTAL_STYLE_CRAGGY);
	Ref<FastNoiseLite> nz = configure_noise(1.0 / std::max(p_feature_size, 0.01), p_octaves,
			p_lacunarity, p_gain, p_seed, ridged);

	// The warp fields are built ONLY when there is a displacement to apply. That is a departure from
	// _make_noise, which builds unconditionally so the C++ and GDScript op tables index in lockstep —
	// here there is no table to index, and an unused pair of FastNoiseLite costs two allocations per bake.
	// The VALUE is identical either way: at warp_amount 0 the offsets are multiplied to nothing.
	const bool warped = p_warp_amount > 0.0;
	Ref<FastNoiseLite> wu, wv;
	if (warped) {
		const double wf = 1.0 / std::max(p_warp_size, 0.01);
		const int ws = p_seed + 7717; // the seed Pasture3DReliefFractal._build emits for its WARP op
		wu = configure_noise(wf, p_warp_octaves, 2.0, 0.5, ws, false);
		wv = configure_noise(wf, p_warp_octaves, 2.0, 0.5, ws + 1013, false);
	}

	const double sharp = p_sharpness;
	float *w = out.ptrw();

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			for (int ix = 0; ix < p_gw; ix++) {
				double u, v;
				graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, u, v);

				if (warped) {
					// Both offsets are read at the UNDISPLACED point, then applied together — the relief
					// evaluator's WARP op, which computes du and dv before touching u.
					const double du = (double)wu->get_noise_2d((real_t)u, (real_t)v) * p_warp_amount;
					const double dv = (double)wv->get_noise_2d((real_t)u, (real_t)v) * p_warp_amount;
					u += du;
					v += dv;
				}

				double raw = (double)nz->get_noise_2d((real_t)u, (real_t)v);
				if (p_style == FRACTAL_STYLE_LUMPY) {
					raw = std::abs(raw) * 2.0 - 1.0;
				} else if (ridged && sharp != 1.0 && sharp > 0.0) {
					raw = (raw < 0.0 ? -1.0 : (raw > 0.0 ? 1.0 : 0.0)) * std::pow(std::abs(raw), sharp);
				}
				w[row + ix] = (float)(raw * p_amplitude);
			}
		}
	});

	return out;
}
