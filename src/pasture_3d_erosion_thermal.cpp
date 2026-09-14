// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_erosion_thermal.h"

#include "pasture_3d_scatter_rows.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

using namespace godot;

namespace {

// One source cell of a thermal pass: how much slipped off it, and how much of that each lower neighbour got.
struct SlipRecord {
	double moved[8];
	double slip;
	uint8_t sent; // bit k: moved[k] went to neighbour k
	bool slipped;
};

// One source cell of a talus-projection pass: what it handed each neighbour it stands too far above.
struct TransferRecord {
	double excess[8];
	uint8_t sent; // bit k: excess[k] left this cell for neighbour k
};

inline double deg_to_rad(double p_deg) {
	return p_deg * (Math_PI / 180.0);
}

} // namespace

Dictionary ErosionThermalResult::to_dict() const {
	Dictionary d;
	d["ok"] = ok;
	d["height"] = height;
	d["talus"] = talus;
	return d;
}

ErosionThermalResult godot::erosion_thermal_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_hardness, int p_gw, int p_gh, const Rect2 &p_rect,
		double p_talus_angle_deg, int p_iterations, double p_settling_rate) {
	ErosionThermalResult res;
	if (p_gw < 1 || p_gh < 1) {
		return res;
	}
	const int n = p_gw * p_gh;
	if (p_surface.size() != n) {
		return res;
	}

	const float *src_h = p_surface.ptr();
	const float *src_hard = (p_hardness.size() == n) ? p_hardness.ptr() : nullptr;

	std::vector<float> height(src_h, src_h + n);
	std::vector<float> next_height(n);
	std::vector<float> talus_accum(n, 0.0f);

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double diag_dist = std::sqrt(dx * dx + dz * dz);

	const double tan_talus = std::tan(deg_to_rad(p_talus_angle_deg));

	const double n_dist[8] = { dx, dx, dz, dz, diag_dist, diag_dist, diag_dist, diag_dist };

	// Every cell sheds into its lower neighbours: a scatter, so a source records what it sheds and each
	// destination replays its terms in raster order — see parallel_scatter_rows.
	const auto compute_row = [&](int iz, SlipRecord *p_records) {
		const int row = iz * p_gw;
		for (int ix = 0; ix < p_gw; ix++) {
			SlipRecord &rec = p_records[ix];
			rec.sent = 0;
			rec.slipped = false;
			const int i = row + ix;
			const double h_c = (double)height[i];
			if (!std::isfinite(h_c)) {
				continue;
			}

			const double hard_c = src_hard ? std::clamp((double)src_hard[i], 0.0, 1.0) : 0.0;
			const double eff_tan = tan_talus * (1.0 + hard_c * 0.75);

			double excess[8] = { 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
			double total_excess = 0.0;
			double max_ex = 0.0;

			for (int k = 0; k < 8; k++) {
				const int nx = ix + SCATTER_DX[k];
				const int nz = iz + SCATTER_DZ[k];
				if (nx >= 0 && nx < p_gw && nz >= 0 && nz < p_gh) {
					const int ni = nz * p_gw + nx;
					const double n_h = (double)height[ni];
					if (std::isfinite(n_h)) {
						const double diff = h_c - n_h;
						const double max_diff = n_dist[k] * eff_tan;
						if (diff > max_diff) {
							const double ex = diff - max_diff;
							excess[k] = ex;
							total_excess += ex;
							if (ex > max_ex) {
								max_ex = ex;
							}
						}
					}
				}
			}

			if (total_excess > 0.0) {
				const double slip_amt = std::clamp(max_ex * 0.5 * p_settling_rate, 0.0, total_excess * 0.5);
				rec.slip = slip_amt;
				rec.slipped = true;

				for (int k = 0; k < 8; k++) {
					if (excess[k] > 0.0) {
						const double frac = excess[k] / total_excess;
						rec.moved[k] = slip_amt * frac;
						rec.sent |= (uint8_t)(1u << k);
					}
				}
			}
		}
	};

	const auto gather_row = [&](int iz, const SlipRecord *p_above, const SlipRecord *p_row,
									const SlipRecord *p_below) {
		const SlipRecord *rows[3] = { p_above, p_row, p_below };
		const int row = iz * p_gw;
		for (int ix = 0; ix < p_gw; ix++) {
			const int i = row + ix;
			float h = height[i];
			float talus = talus_accum[i];
			for (const ScatterSource &src : SCATTER_SOURCES) {
				const int sx = ix + src.dx;
				const SlipRecord *src_row = rows[src.dz + 1];
				if (!src_row || sx < 0 || sx >= p_gw) {
					continue;
				}
				const SlipRecord &rec = src_row[sx];
				if (src.k < 0) {
					if (rec.slipped) {
						h = (float)((double)h - rec.slip);
					}
				} else if (rec.sent & (1u << src.k)) {
					h = (float)((double)h + rec.moved[src.k]);
					talus = (float)((double)talus + rec.moved[src.k]);
				}
			}
			next_height[i] = h;
			// In place: only this row's gather writes it, and no record reads it.
			talus_accum[i] = talus;
		}
	};

	for (int pass = 0; pass < p_iterations; pass++) {
		parallel_scatter_rows<SlipRecord>(p_gw, p_gh, compute_row, gather_row);
		height.swap(next_height);
	}

	double max_talus = 1e-6;
	for (int i = 0; i < n; i++) {
		if (std::isfinite(height[i])) {
			max_talus = std::max(max_talus, (double)talus_accum[i]);
		}
	}

	res.height.resize(n);
	res.talus.resize(n);

	float *out_h = res.height.ptrw();
	float *out_t = res.talus.ptrw();

	for (int i = 0; i < n; i++) {
		if (std::isfinite(height[i])) {
			out_h[i] = height[i];
			out_t[i] = (float)std::clamp((double)talus_accum[i] / max_talus, 0.0, 1.0);
		} else {
			out_h[i] = height[i];
			out_t[i] = 0.0f;
		}
	}

	res.ok = true;
	return res;
}

PackedFloat32Array godot::talus_projection_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh, const Rect2 &p_rect,
		double p_talus_angle_deg, int p_iterations, double p_transfer_rate, double p_amount) {
	const int n = p_gw * p_gh;
	if (p_surface.size() != n || n <= 0) {
		PackedFloat32Array empty;
		empty.resize(n);
		return empty;
	}

	if (p_amount <= 1e-6 || p_iterations <= 0) {
		return p_surface.duplicate();
	}

	const float *src_h = p_surface.ptr();
	const float *src_m = (p_mask.size() == n) ? p_mask.ptr() : nullptr;

	std::vector<float> h(src_h, src_h + n);
	std::vector<float> next_h(n);

	const double dx = (p_rect.size.x > 0.0 && p_gw > 1) ? ((double)p_rect.size.x / std::max((double)(p_gw - 1), 1.0)) : 2.0;
	const double dz = (p_rect.size.y > 0.0 && p_gh > 1) ? ((double)p_rect.size.y / std::max((double)(p_gh - 1), 1.0)) : 2.0;
	const double diag_d = std::sqrt(dx * dx + dz * dz);

	const double tan_talus = std::tan(deg_to_rad(p_talus_angle_deg));
	const double rate = p_transfer_rate * 0.25;

	const double dist[8] = { dx, dx, dz, dz, diag_d, diag_d, diag_d, diag_d };

	// The serial pass summed every transfer into a delta grid in raster order, then applied it. The delta is
	// now summed per destination instead, from records, in that same order — see parallel_scatter_rows.
	const auto compute_row = [&](int iz, TransferRecord *p_records) {
		const int row = iz * p_gw;
		for (int ix = 0; ix < p_gw; ix++) {
			TransferRecord &rec = p_records[ix];
			rec.sent = 0;
			const int i = row + ix;
			const double hi = (double)h[i];
			if (!std::isfinite(hi)) {
				continue;
			}

			for (int k = 0; k < 8; k++) {
				const int nx = ix + SCATTER_DX[k];
				const int nz = iz + SCATTER_DZ[k];
				if (nx < 0 || nx >= p_gw || nz < 0 || nz >= p_gh) {
					continue;
				}

				const int ni = nz * p_gw + nx;
				const double hni = (double)h[ni];
				if (!std::isfinite(hni)) {
					continue;
				}

				const double diff = hi - hni;
				const double max_diff = dist[k] * tan_talus;

				if (diff > max_diff) {
					rec.excess[k] = (diff - max_diff) * rate;
					rec.sent |= (uint8_t)(1u << k);
				}
			}
		}
	};

	const auto gather_row = [&](int iz, const TransferRecord *p_above, const TransferRecord *p_row,
									const TransferRecord *p_below) {
		const TransferRecord *rows[3] = { p_above, p_row, p_below };
		const int row = iz * p_gw;
		for (int ix = 0; ix < p_gw; ix++) {
			double delta = 0.0;
			for (const ScatterSource &src : SCATTER_SOURCES) {
				const int sx = ix + src.dx;
				const TransferRecord *src_row = rows[src.dz + 1];
				if (!src_row || sx < 0 || sx >= p_gw) {
					continue;
				}
				const TransferRecord &rec = src_row[sx];
				if (src.k < 0) {
					// The cell's own outflows, in the order its neighbour loop sent them.
					for (int k = 0; k < 8; k++) {
						if (rec.sent & (1u << k)) {
							delta -= rec.excess[k];
						}
					}
				} else if (rec.sent & (1u << src.k)) {
					delta += rec.excess[src.k];
				}
			}
			const int i = row + ix;
			next_h[i] = std::isfinite(h[i]) ? (float)((double)h[i] + delta) : h[i];
		}
	};

	for (int iter = 0; iter < p_iterations; iter++) {
		parallel_scatter_rows<TransferRecord>(p_gw, p_gh, compute_row, gather_row);
		h.swap(next_h);
	}

	PackedFloat32Array out;
	out.resize(n);
	float *dst = out.ptrw();

	for (int i = 0; i < n; i++) {
		if (std::isfinite(src_h[i]) && std::isfinite(h[i])) {
			const double m = src_m ? std::clamp((double)src_m[i], 0.0, 1.0) : 1.0;
			dst[i] = (float)((double)src_h[i] + ((double)h[i] - (double)src_h[i]) * (p_amount * m));
		} else {
			dst[i] = src_h[i];
		}
	}

	return out;
}
