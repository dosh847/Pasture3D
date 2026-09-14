// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_erosion_hydraulic.h"

#include "pasture_3d_scatter_rows.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>

using namespace godot;

namespace {

// One source cell of the routing sweep: what it did to itself, and what it sent each neighbour.
struct RoutingRecord {
	double moved_w[4];
	double moved_s[4];
	double height_amt; // subtracted under ERODE, added under DEPOSIT
	double flow_out; // subtracted from the cell's own water
	double sed_delta; // the sediment it kept, minus the sediment it started the pass with
	uint8_t flags;
	uint8_t sent; // bit k: moved_w[k] and moved_s[k] went to neighbour k
};

constexpr uint8_t ROUTED = 1; // the cell had water and somewhere downhill to send it
constexpr uint8_t ERODE = 2;
constexpr uint8_t DEPOSIT = 4;

} // namespace

ErosionHydraulicParams ErosionHydraulicParams::from_dict(const Dictionary &p_dict) {
	ErosionHydraulicParams p;
	if (p_dict.has("iterations")) {
		p.iterations = std::max(1, (int)p_dict["iterations"]);
	}
	if (p_dict.has("rain_rate")) {
		p.rain_rate = std::max(0.0, (double)p_dict["rain_rate"]);
	}
	if (p_dict.has("evaporation_rate")) {
		p.evaporation_rate = std::clamp((double)p_dict["evaporation_rate"], 0.0, 1.0);
	}
	if (p_dict.has("sediment_capacity")) {
		p.sediment_capacity = std::max(0.0, (double)p_dict["sediment_capacity"]);
	}
	if (p_dict.has("erosion_speed")) {
		p.erosion_speed = std::clamp((double)p_dict["erosion_speed"], 0.0, 1.0);
	}
	if (p_dict.has("deposition_speed")) {
		p.deposition_speed = std::clamp((double)p_dict["deposition_speed"], 0.0, 1.0);
	}
	if (p_dict.has("min_slope")) {
		p.min_slope = std::max(0.0, (double)p_dict["min_slope"]);
	}
	return p;
}

Dictionary ErosionHydraulicResult::to_dict() const {
	Dictionary d;
	d["ok"] = ok;
	d["height"] = height;
	d["sediment"] = sediment;
	d["flow"] = flow;
	return d;
}

ErosionHydraulicResult godot::erosion_hydraulic_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const ErosionHydraulicParams &p_params) {
	ErosionHydraulicResult res;
	if (p_gw < 1 || p_gh < 1) {
		return res;
	}
	const int n = p_gw * p_gh;
	if (p_surface.size() != n) {
		return res;
	}

	const float *src_height = p_surface.ptr();
	std::vector<float> height(src_height, src_height + n);
	std::vector<float> sediment(n, 0.0f);
	std::vector<float> water(n, 0.0f);
	std::vector<float> flow_accum(n, 0.0f);
	// The routing sweep writes every cell of these, so each pass swaps them with the state rather than
	// copying the state into them first.
	std::vector<float> next_height(n);
	std::vector<float> next_sediment(n);
	std::vector<float> next_water(n);
	std::vector<float> next_flow(n);

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double cell_dist = std::sqrt(std::max(dx * dz, 1e-6));

	const double n_dist[4] = { dx, dx, dz, dz };

	const int iterations = p_params.iterations;
	const double p_rain = (double)p_params.rain_rate;
	const double p_evap = (double)p_params.evaporation_rate;
	const double p_cap = (double)p_params.sediment_capacity;
	const double p_ero_spd = (double)p_params.erosion_speed;
	const double p_dep_spd = (double)p_params.deposition_speed;
	const double p_min_slope = (double)p_params.min_slope;

	// 2. Downhill flow routing & stream power incision, as a scatter: each cell pushes water, sediment and flow
	// into its downhill neighbours, and each of those is a float sum whose bits depend on the order its terms
	// arrive in. So a source records what it sends (compute_row) and each destination replays its terms in the
	// serial sweep's raster order (gather_row) — see parallel_scatter_rows.
	//
	// Everything a record reads is the state at the START of the pass. For flow_accum that was once a bug fix:
	// the sweep read the live array while scattering into it, so the carrying capacity at a cell depended on
	// whether its upstream neighbour happened to be visited first — raster order deciding how much sediment a
	// cell could hold. The GPU's two-phase split always read the snapshot.
	const auto compute_row = [&](int iz, RoutingRecord *p_records) {
		const int row = iz * p_gw;
		for (int ix = 0; ix < p_gw; ix++) {
			RoutingRecord &rec = p_records[ix];
			rec.flags = 0;
			rec.sent = 0;
			const int i = row + ix;
			const double h_c = (double)height[i];
			const double w_c = (double)water[i];
			if (!std::isfinite(h_c) || w_c <= 1e-7) {
				continue;
			}

			const double total_alt = h_c + w_c;
			double diffs[4] = { 0.0, 0.0, 0.0, 0.0 };
			double total_diff = 0.0;
			double max_slope = 0.0;
			double min_downhill_diff = std::numeric_limits<double>::infinity();

			for (int k = 0; k < 4; k++) {
				const int nx = ix + SCATTER_DX[k];
				const int nz = iz + SCATTER_DZ[k];
				if (nx >= 0 && nx < p_gw && nz >= 0 && nz < p_gh) {
					const int ni = nz * p_gw + nx;
					const double n_h = (double)height[ni];
					const double n_w = (double)water[ni];
					if (std::isfinite(n_h)) {
						const double n_total = n_h + n_w;
						const double diff = total_alt - n_total;
						if (diff > 0.0) {
							diffs[k] = diff;
							total_diff += diff;
							min_downhill_diff = std::min(min_downhill_diff, diff);
							const double slope = diff / n_dist[k];
							if (slope > max_slope) {
								max_slope = slope;
							}
						}
					}
				}
			}

			if (total_diff > 0.0) {
				rec.flags = ROUTED;
				const double eff_slope = std::max(max_slope, p_min_slope);
				const double vel = std::sqrt(std::clamp(eff_slope * cell_dist, 0.05, 50.0));
				const double flow_factor = std::log(1.0 + (double)flow_accum[i] * 10.0) + 1.0;
				const double cap = p_cap * eff_slope * vel * w_c * flow_factor * 0.5;

				double sed_c = (double)sediment[i];
				const double max_erode = min_downhill_diff * 0.4;
				const double max_dep = min_downhill_diff * 0.4;

				if (sed_c < cap) {
					const double erode_amt = std::clamp((cap - sed_c) * p_ero_spd * 0.4, 0.0, max_erode);
					rec.flags |= ERODE;
					rec.height_amt = erode_amt;
					sed_c += erode_amt;
				} else if (sed_c > cap) {
					const double dep_amt = std::clamp((sed_c - cap) * p_dep_spd * 0.4, 0.0, max_dep);
					rec.flags |= DEPOSIT;
					rec.height_amt = dep_amt;
					sed_c -= dep_amt;
				}

				const double flow_out = std::min(w_c * 0.6, total_diff * 0.5);
				rec.flow_out = flow_out;

				for (int k = 0; k < 4; k++) {
					if (diffs[k] > 0.0) {
						const double frac = diffs[k] / total_diff;
						const double moved_w = flow_out * frac;
						const double moved_s = sed_c * (moved_w / std::max(w_c, 1e-6));
						rec.moved_w[k] = moved_w;
						rec.moved_s[k] = moved_s;
						rec.sent |= (uint8_t)(1u << k);
						sed_c = std::max(sed_c - moved_s, 0.0);
					}
				}
				rec.sed_delta = sed_c - (double)sediment[i];
			}
		}
	};

	const auto gather_row = [&](int iz, const RoutingRecord *p_above, const RoutingRecord *p_row,
									const RoutingRecord *p_below) {
		const RoutingRecord *rows[3] = { p_above, p_row, p_below };
		const int row = iz * p_gw;
		for (int ix = 0; ix < p_gw; ix++) {
			const int i = row + ix;
			float h = height[i];
			float w = water[i];
			float s = sediment[i];
			float f = flow_accum[i];
			for (const ScatterSource &src : SCATTER_SOURCES) {
				const int sx = ix + src.dx;
				const RoutingRecord *src_row = rows[src.dz + 1];
				// Routing is 4-neighbour: no diagonal ever sent anything here.
				if (src.k >= 4 || !src_row || sx < 0 || sx >= p_gw) {
					continue;
				}
				const RoutingRecord &rec = src_row[sx];
				if (src.k < 0) {
					if (rec.flags & ROUTED) {
						if (rec.flags & ERODE) {
							h = (float)((double)h - rec.height_amt);
						} else if (rec.flags & DEPOSIT) {
							h = (float)((double)h + rec.height_amt);
						}
						w = (float)((double)w - rec.flow_out);
						// += the DELTA, not = the retained amount. An assignment threw away every grain an
						// already-visited upstream neighbour had delivered here — a scan-order-dependent loss no
						// other channel showed, because water and flow both accumulate. The GPU keeps the
						// retained amount and the inbound flux in separate buffers and was always right.
						s = (float)((double)s + rec.sed_delta);
					}
				} else if (rec.sent & (1u << src.k)) {
					w = (float)((double)w + rec.moved_w[src.k]);
					s = (float)((double)s + rec.moved_s[src.k]);
					f = (float)((double)f + rec.moved_w[src.k]);
				}
			}
			// 3. Evaporation — per cell and after every term, so it folds into the gather.
			if (std::isfinite(h)) {
				w = (float)((double)w * (1.0 - p_evap));
			}
			next_height[i] = h;
			next_water[i] = w;
			next_sediment[i] = s;
			next_flow[i] = f;
		}
	};

	for (int pass = 0; pass < iterations; pass++) {
		// 1. Rain
		Pasture3DThreadPool::parallel_for_elements(n, 4096, [&](int p_begin, int p_end) {
			for (int i = p_begin; i < p_end; i++) {
				if (std::isfinite(height[i])) {
					water[i] = (float)((double)water[i] + p_rain);
					flow_accum[i] = (float)((double)flow_accum[i] + p_rain);
				}
			}
		});

		parallel_scatter_rows<RoutingRecord>(p_gw, p_gh, compute_row, gather_row);

		height.swap(next_height);
		water.swap(next_water);
		sediment.swap(next_sediment);
		flow_accum.swap(next_flow);
	}

	// 4. Normalization for mask channels
	double max_flow = 1e-6;
	double max_sed = 1e-6;
	for (int i = 0; i < n; i++) {
		if (std::isfinite(height[i])) {
			max_flow = std::max(max_flow, (double)flow_accum[i]);
			max_sed = std::max(max_sed, (double)sediment[i]);
		}
	}

	res.height.resize(n);
	res.sediment.resize(n);
	res.flow.resize(n);

	float *out_h = res.height.ptrw();
	float *out_s = res.sediment.ptrw();
	float *out_f = res.flow.ptrw();

	for (int i = 0; i < n; i++) {
		if (std::isfinite(height[i])) {
			out_h[i] = height[i];
			out_s[i] = (float)std::clamp((double)sediment[i] / max_sed, 0.0, 1.0);
			out_f[i] = (float)std::clamp((double)flow_accum[i] / max_flow, 0.0, 1.0);
		} else {
			out_h[i] = height[i];
			out_s[i] = 0.0f;
			out_f[i] = 0.0f;
		}
	}

	res.ok = true;
	return res;
}
