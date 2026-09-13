// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_hydraulic_stream_log.h"

#include "pasture_3d_thread_pool.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <numeric>
#include <vector>

using namespace godot;

HydraulicStreamLogParams HydraulicStreamLogParams::from_dict(const Dictionary &p_dict) {
	HydraulicStreamLogParams p;
	if (p_dict.has("iterations")) {
		p.iterations = std::max(1, (int)p_dict["iterations"]);
	}
	if (p_dict.has("incision_rate")) {
		p.incision_rate = std::max(0.0f, (float)p_dict["incision_rate"]);
	}
	if (p_dict.has("area_exponent")) {
		p.area_exponent = std::clamp((float)p_dict["area_exponent"], 0.01f, 2.0f);
	}
	if (p_dict.has("slope_exponent")) {
		p.slope_exponent = std::clamp((float)p_dict["slope_exponent"], 0.01f, 2.0f);
	}
	if (p_dict.has("min_catchment")) {
		p.min_catchment = std::max(0.0f, (float)p_dict["min_catchment"]);
	}
	if (p_dict.has("bank_smoothing")) {
		p.bank_smoothing = std::clamp((float)p_dict["bank_smoothing"], 0.0f, 0.5f);
	}
	if (p_dict.has("peak_preservation")) {
		p.peak_preservation = std::clamp((float)p_dict["peak_preservation"], 0.0f, 1.0f);
	}
	if (p_dict.has("gradient_power")) {
		p.gradient_power = std::clamp((float)p_dict["gradient_power"], 0.1f, 2.0f);
	}
	if (p_dict.has("mask")) {
		p.mask = p_dict["mask"];
	}
	return p;
}

Dictionary HydraulicStreamLogResult::to_dict() const {
	Dictionary d;
	d["ok"] = ok;
	d["height"] = height;
	d["channel_mask"] = channel_mask;
	d["flow_accumulation"] = flow_accumulation;
	return d;
}

namespace {

// Monotone float -> uint32 map, then inverted, so sorting the keys ASCENDING sorts the elevations
// DESCENDING -- which is the order the routing walk in stage 2 needs.
//
// A non-finite height maps somewhere arbitrary and that is deliberate: stage 2 skips non-finite cells by
// VALUE, so where they sit in the order is never read. The comparator this replaces spent two isfinite
// calls per comparison establishing an ordering nothing consumed.
static inline uint32_t elev_rank(float p_h) {
	uint32_t b;
	std::memcpy(&b, &p_h, sizeof(b));
	b = (b & 0x80000000u) ? ~b : (b | 0x80000000u);
	return ~b;
}

// Four-pass LSD radix sort of cell indices by elevation, descending.
//
// Replaces a std::sort over the same indices whose comparator gathered `height[a]` and `height[b]` at
// random offsets -- ~20 million cache-missing comparisons per pass at 1024x1024, and the solver runs one
// sort PER PASS. The radix version is four linear scans over a key array it builds once.
static void sort_by_elevation_desc(const std::vector<float> &p_height, std::vector<uint32_t> &p_keys,
		std::vector<int> &p_order, std::vector<int> &p_scratch) {
	const int n = (int)p_height.size();
	for (int i = 0; i < n; i++) {
		p_keys[i] = elev_rank(p_height[i]);
		p_order[i] = i;
	}

	uint32_t hist[4][256] = {};
	for (int i = 0; i < n; i++) {
		const uint32_t k = p_keys[i];
		hist[0][k & 0xFFu]++;
		hist[1][(k >> 8) & 0xFFu]++;
		hist[2][(k >> 16) & 0xFFu]++;
		hist[3][(k >> 24) & 0xFFu]++;
	}

	for (int b = 0; b < 4; b++) {
		uint32_t sum = 0;
		for (int v = 0; v < 256; v++) {
			const uint32_t c = hist[b][v];
			hist[b][v] = sum;
			sum += c;
		}
		const int shift = b * 8;
		for (int i = 0; i < n; i++) {
			const int idx = p_order[i];
			p_scratch[hist[b][(p_keys[idx] >> shift) & 0xFFu]++] = idx;
		}
		// Four passes and a swap after each, so the answer lands back in `p_order`.
		p_order.swap(p_scratch);
	}
}

// drop^1.3, the MD8 routing weight. Kept as an exact std::pow deliberately.
//
// This is the hottest line in the solver -- up to eight calls per cell per pass, ~120 million for a
// default 15-iteration solve at 1024x1024 -- and the obvious win is to approximate it, drop^1.25 via two
// hardware sqrts being both cheap and visually identical. It is NOT taken, because
// GraphHydraulicStreamLogGate holds this kernel to bit-level parity with the GDScript oracle in
// pasture3d_graph_node_hydraulic_stream_log.gd, and 1.25 moves flow accumulation by 17 units against a
// 5e-6 tolerance. The oracle is the specification, so the kernel does not get to redefine it.
//
// If this exponent is ever worth approximating, the oracle changes FIRST and the gate proves the two
// still agree. See [[evaluate-is-not-an-oracle]] for why chasing it the other way proves nothing.
static inline double drop_weight(double p_drop) {
	return std::pow(p_drop, 1.3);
}

// x^e for the two exponents the solver is actually configured with almost all of the time. Otherwise each
// of these is a full libm call, three times per cell in stage 3.
static inline double pow_fast(double p_x, double p_e) {
	if (p_e == 1.0) {
		return p_x;
	}
	if (p_e == 0.5) {
		return std::sqrt(p_x);
	}
	return std::pow(p_x, p_e);
}

} // namespace

HydraulicStreamLogResult godot::hydraulic_stream_log_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const HydraulicStreamLogParams &p_params) {
	HydraulicStreamLogResult res;
	if (p_gw < 2 || p_gh < 2) {
		return res;
	}
	const int n = p_gw * p_gh;
	if (p_surface.size() != n) {
		return res;
	}

	const float *src_height = p_surface.ptr();
	std::vector<float> height(src_height, src_height + n);
	std::vector<float> channel_mask(n, 0.0f);
	std::vector<float> flow_accum(n, 0.0f);

	const bool has_mask = (p_params.mask.size() == n);
	const float *mask_ptr = has_mask ? p_params.mask.ptr() : nullptr;

	const int iterations = std::max(1, p_params.iterations);
	const double incision_rate = (double)p_params.incision_rate;
	const double area_exponent = (double)p_params.area_exponent;
	const double slope_exponent = (double)p_params.slope_exponent;
	const double min_catchment = (double)p_params.min_catchment;
	const double bank_smoothing = (double)p_params.bank_smoothing;
	const double peak_preservation = (double)p_params.peak_preservation;
	const double gradient_power = (double)p_params.gradient_power;

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double diag_dist = std::sqrt(dx * dx + dz * dz);

	const int n_dx[8] = { -1, 1, 0, 0, -1, 1, -1, 1 };
	const int n_dz[8] = { 0, 0, -1, 1, -1, -1, 1, 1 };
	const double n_dist[8] = { dx, dx, dz, dz, diag_dist, diag_dist, diag_dist, diag_dist };
	// Bank spreading is a fixed 5-tap stencil; both weights are constants of the parameters.
	const double center_weight = 1.0 - bank_smoothing * 0.6;
	const double neighbor_weight = (bank_smoothing * 0.6) * 0.25;

	// EVERY buffer the pass loop needs, allocated ONCE. The original allocated `current_flow`,
	// `incision_map` and a whole copy of `height` INSIDE the loop -- three heap allocations and ~16 MB of
	// zero-fill per pass at 1024x1024, fifteen times over.
	std::vector<int> order(n);
	std::vector<int> order_scratch(n);
	std::vector<uint32_t> keys(n);
	std::vector<float> current_flow(n);
	std::vector<double> cell_incision(n);
	std::vector<double> incision_map(n);
	std::vector<float> next_height(n);

	for (int pass = 0; pass < iterations; pass++) {
		// 1. Order cells descending by elevation.
		sort_by_elevation_desc(height, keys, order, order_scratch);

		// 2. Accumulate drainage flow using MD8 multi-direction routing.
		//
		// SEQUENTIAL BY CONSTRUCTION, and left that way: each cell pushes its accumulated flow down to
		// lower neighbours, so a cell must be visited after everything that drains into it. That is what
		// the ordering above is for, and it is why this is the one stage below that is not threaded.
		std::fill(current_flow.begin(), current_flow.end(), 1.0f);

		for (int idx : order) {
			float h_c = height[idx];
			if (!std::isfinite(h_c)) {
				continue;
			}
			int cx = idx % p_gw;
			int cz = idx / p_gw;

			double sum_drop = 0.0;
			double drops[8] = { 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };

			for (int k = 0; k < 8; k++) {
				int nx = cx + n_dx[k];
				int nz = cz + n_dz[k];
				if (nx >= 0 && nx < p_gw && nz >= 0 && nz < p_gh) {
					int n_idx = nz * p_gw + nx;
					float h_n = height[n_idx];
					if (std::isfinite(h_n) && h_n < h_c) {
						double drop = (double)(h_c - h_n) / n_dist[k];
						double weighted_drop = drop_weight(drop);
						drops[k] = weighted_drop;
						sum_drop += weighted_drop;
					}
				}
			}

			if (sum_drop > 1.0e-6) {
				double my_flow = (double)current_flow[idx];
				for (int k = 0; k < 8; k++) {
					if (drops[k] > 0.0) {
						int nx = cx + n_dx[k];
						int nz = cz + n_dz[k];
						int n_idx = nz * p_gw + nx;
						double frac = drops[k] / sum_drop;
						current_flow[n_idx] = (float)((double)current_flow[n_idx] + my_flow * frac);
					}
				}
			}
		}

		// 3a. Per-cell incision, BEFORE bank spreading. Pure: reads `height`, `current_flow` and the mask,
		// writes only its own cell. Threaded by rows.
		Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int p_z0, int p_z1) {
			for (int iz = p_z0; iz < p_z1; iz++) {
				int row = iz * p_gw;
				for (int ix = 0; ix < p_gw; ix++) {
					int idx = row + ix;
					cell_incision[idx] = 0.0;

					float h_c = height[idx];
					if (!std::isfinite(h_c)) {
						continue;
					}

					double m_val = has_mask ? (double)mask_ptr[idx] : 1.0;
					if (m_val <= 0.001) {
						continue;
					}

					float h_l = (ix > 0 && std::isfinite(height[row + ix - 1])) ? height[row + ix - 1] : h_c;
					float h_r = (ix < p_gw - 1 && std::isfinite(height[row + ix + 1])) ? height[row + ix + 1] : h_c;
					float h_u = (iz > 0 && std::isfinite(height[(iz - 1) * p_gw + ix])) ? height[(iz - 1) * p_gw + ix] : h_c;
					float h_d = (iz < p_gh - 1 && std::isfinite(height[(iz + 1) * p_gw + ix])) ? height[(iz + 1) * p_gw + ix] : h_c;

					double gx = (double)(h_r - h_l) / (2.0 * dx);
					double gz = (double)(h_d - h_u) / (2.0 * dz);
					double slope = std::sqrt(gx * gx + gz * gz);

					// Hesiod gradient power shaping
					double shaped_slope = (gradient_power != 1.0) ? pow_fast(slope, gradient_power) : slope;

					// Hesiod relative elevation peak preservation kernel (radius 2)
					double peak_weight = 1.0;
					if (peak_preservation > 0.0) {
						float min_local = h_c;
						float max_local = h_c;
						for (int rz = std::max(0, iz - 2); rz <= std::min(p_gh - 1, iz + 2); rz++) {
							for (int rx = std::max(0, ix - 2); rx <= std::min(p_gw - 1, ix + 2); rx++) {
								float val = height[rz * p_gw + rx];
								if (std::isfinite(val)) {
									if (val < min_local) min_local = val;
									if (val > max_local) max_local = val;
								}
							}
						}
						double range = (double)(max_local - min_local);
						if (range > 1.0e-4) {
							double re = ((double)h_c - (double)min_local) / range;
							double s_re = re * re * (3.0 - 2.0 * re); // smoothstep3
							peak_weight = (1.0 - peak_preservation) + peak_preservation * (1.0 - s_re);
						}
					}

					// Smooth softplus transition for catchment activation
					double diff = (double)current_flow[idx] - min_catchment;
					double a_accum = (diff > 15.0) ? diff : ((diff > -15.0) ? std::log(1.0 + std::exp(diff)) : 0.0);

					if (a_accum > 0.01 && slope > 1.0e-5) {
						double power = pow_fast(a_accum, area_exponent) * pow_fast(shaped_slope, slope_exponent);
						cell_incision[idx] = incision_rate * std::log(1.0 + power) * peak_weight * m_val;
					}

					flow_accum[idx] = current_flow[idx];
				}
			}
		});

		// 3b. Lateral bank spreading, as a GATHER rather than the scatter it was.
		//
		// Exactly the same stencil read from the other end: a cell used to PUSH `neighbor_weight` into each
		// of its four edge neighbours, so each cell now PULLS `neighbor_weight` from each of the four that
		// would have pushed it. The boundary cases line up -- a cell at ix == 0 pushed nothing to its left
		// and now pulls nothing from its left -- and a cell that produced no incision contributes zero
		// either way. Turning it around is what makes it safe to thread: the scatter wrote across rows.
		Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int p_z0, int p_z1) {
			for (int iz = p_z0; iz < p_z1; iz++) {
				int row = iz * p_gw;
				for (int ix = 0; ix < p_gw; ix++) {
					int idx = row + ix;
					double sum = cell_incision[idx] * center_weight;
					if (ix > 0) {
						sum += cell_incision[idx - 1] * neighbor_weight;
					}
					if (ix < p_gw - 1) {
						sum += cell_incision[idx + 1] * neighbor_weight;
					}
					if (iz > 0) {
						sum += cell_incision[idx - p_gw] * neighbor_weight;
					}
					if (iz < p_gh - 1) {
						sum += cell_incision[idx + p_gw] * neighbor_weight;
					}
					incision_map[idx] = sum;
				}
			}
		});

		// 4. Apply incision with base-level descent clamping. Reads `height`, writes only `next_height` and
		// `channel_mask` at its own cell, so it threads by rows unchanged.
		std::memcpy(next_height.data(), height.data(), (size_t)n * sizeof(float));
		Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int p_z0, int p_z1) {
			for (int iz = p_z0; iz < p_z1; iz++) {
				int row = iz * p_gw;
				for (int ix = 0; ix < p_gw; ix++) {
					int idx = row + ix;
					float h_c = height[idx];
					if (!std::isfinite(h_c)) {
						continue;
					}

					double cut = incision_map[idx];
					if (cut > 0.0) {
						int cx = ix;
						int cz = iz;
						float min_downhill = h_c;
						for (int k = 0; k < 8; k++) {
							int nx = cx + n_dx[k];
							int nz = cz + n_dz[k];
							if (nx >= 0 && nx < p_gw && nz >= 0 && nz < p_gh) {
								float h_n = height[nz * p_gw + nx];
								if (std::isfinite(h_n) && h_n < min_downhill) {
									min_downhill = h_n;
								}
							}
						}

						double max_cut = std::max(0.0, (double)(h_c - min_downhill) + 0.05 * cut);
						cut = std::min(cut, max_cut);
						next_height[idx] = (float)((double)h_c - cut);
						float normalized_cut = std::clamp((float)(cut / (incision_rate * 2.0 + 1.0e-5)), 0.0f, 1.0f);
						channel_mask[idx] = std::max(channel_mask[idx], normalized_cut);
					}
				}
			}
		});

		// Swap, not assign: `next_height` was memcpy-seeded from `height` above, so after the swap it is
		// free scratch for the next pass and nothing is reallocated.
		height.swap(next_height);
	}

	res.ok = true;
	res.height.resize(n);
	std::memcpy(res.height.ptrw(), height.data(), (size_t)n * sizeof(float));

	res.channel_mask.resize(n);
	std::memcpy(res.channel_mask.ptrw(), channel_mask.data(), (size_t)n * sizeof(float));

	res.flow_accumulation.resize(n);
	std::memcpy(res.flow_accumulation.ptrw(), flow_accum.data(), (size_t)n * sizeof(float));

	return res;
}
