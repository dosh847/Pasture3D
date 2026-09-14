// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_mudslide.h"

#include "pasture_3d_scatter_rows.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

using namespace godot;

namespace {

// A slide that runs for a very long distance on a very fine grid would otherwise sweep forever. 4096 is
// far past anything an author would set deliberately and well short of a hang.
constexpr int MAX_SWEEPS = 4096;

// How much of a cell's mobile pool moves per METRE travelled, expressed as a multiple of cell/travel. The
// per-sweep fraction is derived from it below.
//
// Two things had to be got right here and both were found by measurement, not by reasoning ahead — see
// GraphMudslideGate MG.
//
// First, transport is driven by the POOL, not by the local height excess. Limiting the per-sweep transfer to
// the excess (the obvious first formulation, and the one this file originally had) is DIFFUSION, whose
// spread goes as cell² per sweep, so the same slide ran shorter every time the grid was refined.
//
// Second, a constant per-SWEEP fraction is not invariant either, and this is the subtler one. Material
// advances one cell per sweep, so covering a fixed distance takes travel/cell sweeps; if each sweep passed
// on a fixed fraction, the material reaching the far end would be that fraction raised to a power that
// doubles when the grid is refined, and the slide would thin out twice as fast for no physical reason. The
// fraction therefore scales with cell/travel, which makes the fraction moved over any given stretch of
// GROUND — and so the whole deposit profile — a function of world distance alone.
constexpr double TRANSPORT_GAIN = 0.25;

// One source cell of a sweep: what it gave each lower neighbour. It loses the same amounts, from its height
// and its mobile pool alike.
struct SlideRecord {
	double give[8];
	uint8_t sent; // bit k: give[k] went to neighbour k
};

} // namespace

PackedFloat32Array godot::mudslide_solve(const PackedFloat32Array &p_surface,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh, const Rect2 &p_rect,
		double p_talus_angle_deg, double p_depth_m, double p_travel_distance_m, double p_depth_exponent,
		double p_viscosity_power, double p_amount, PackedFloat32Array *r_deposition,
		double *r_deposition_divisor) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	if (p_gw <= 0 || p_gh <= 0 || p_surface.size() != n) {
		return out;
	}
	if (r_deposition_divisor) {
		*r_deposition_divisor = 1.0;
	}

	const float *src = p_surface.ptr();
	if (p_amount <= 0.0 || p_depth_m <= 0.0 || p_travel_distance_m <= 0.0) {
		if (r_deposition) {
			r_deposition->resize(n);
			r_deposition->fill(0.f);
		}
		return p_surface.duplicate();
	}

	// dx divides by gw, NOT gw-1 — the same convention as Pasture3DTerrainGraph.cell_to_world. Half the
	// metric-units bugs in this codebase have been one of those two expressions meeting the other.
	const double dx = (double)p_rect.size.x / (double)p_gw;
	const double dz = (double)p_rect.size.y / (double)p_gh;
	const double diag = std::sqrt(dx * dx + dz * dz);
	const double cell = std::min(dx, dz);
	if (cell <= 0.0) {
		return p_surface.duplicate();
	}

	// Material advances roughly one cell per sweep, so the sweep count IS the travel distance divided by
	// the cell size. This one line is what makes the node resolution-invariant.
	const int sweeps = std::clamp((int)std::lround(p_travel_distance_m / cell), 1, MAX_SWEEPS);

	// The per-sweep fraction, capped at half the pool so a single sweep can never drain a cell outright.
	const double step_fraction =
			std::clamp(TRANSPORT_GAIN, 0.0, 0.5);

	const double kPi = 3.14159265358979323846;
	const double tan_repose = std::tan(std::clamp(p_talus_angle_deg, 0.0, 89.0) * kPi / 180.0);

	// Distance to neighbour k along SCATTER_DX/DZ.
	const double dist[8] = { dx, dx, dz, dz, diag, diag, diag, diag };

	std::vector<double> h((size_t)n);
	for (int i = 0; i < n; i++) {
		h[(size_t)i] = (double)src[i];
	}

	// --- the mobile pool -----------------------------------------------------------------------------
	// Either the mask says where the material is, or the terrain does. A wired mask wins outright: the
	// whole reason this node exists is to put a slide on a hillside the author chose.
	// An all-zero mask counts as NO mask, not as "no material anywhere".
	//
	// This is forced by the graph, not chosen: Pasture3DTerrainGraph feeds an unwired port an n-sized grid
	// of zeros ("a missing connection is a clean 0"), so by the time the array arrives here an unwired mask
	// and a deliberately blank one are the same bytes. One of the two readings has to win, and falling back
	// to the talus gate is the one that leaves the node useful — the other makes an unwired mask a silent
	// pass-through.
	bool have_mask = (p_mask.size() == n);
	if (have_mask) {
		bool any = false;
		const float *probe = p_mask.ptr();
		for (int i = 0; i < n && !any; i++) {
			any = std::isfinite(probe[i]) && probe[i] > 0.0f;
		}
		have_mask = any;
	}
	const float *mk = have_mask ? p_mask.ptr() : nullptr;
	std::vector<double> mobile((size_t)n, 0.0);

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int p_z0, int p_z1) {
		for (int iz = p_z0; iz < p_z1; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = iz * p_gw + ix;
				if (!std::isfinite(h[(size_t)i])) {
					continue;
				}
				if (have_mask) {
					const double m = (double)mk[i];
					mobile[(size_t)i] = p_depth_m * (std::isfinite(m) ? std::clamp(m, 0.0, 1.0) : 0.0);
					continue;
				}
				const int xm = std::max(ix - 1, 0);
				const int xp = std::min(ix + 1, p_gw - 1);
				const int zm = std::max(iz - 1, 0);
				const int zp = std::min(iz + 1, p_gh - 1);
				const double hxm = h[(size_t)(iz * p_gw + xm)];
				const double hxp = h[(size_t)(iz * p_gw + xp)];
				const double hzm = h[(size_t)(zm * p_gw + ix)];
				const double hzp = h[(size_t)(zp * p_gw + ix)];
				if (!std::isfinite(hxm) || !std::isfinite(hxp) || !std::isfinite(hzm) || !std::isfinite(hzp)) {
					continue;
				}
				const double gx = (hxp - hxm) / ((double)(xp - xm) * dx);
				const double gz = (hzp - hzm) / ((double)(zp - zm) * dz);
				if (std::sqrt(gx * gx + gz * gz) > tan_repose) {
					mobile[(size_t)i] = p_depth_m;
				}
			}
		}
	});

	// Every cell gives to its lower neighbours: a scatter, so a source records what it gives and each
	// destination replays its terms in raster order — see parallel_scatter_rows.
	const auto compute_row = [&](int iz, SlideRecord *p_records) {
		for (int ix = 0; ix < p_gw; ix++) {
			SlideRecord &rec = p_records[ix];
			rec.sent = 0;
			const int i = iz * p_gw + ix;
			const double m = mobile[(size_t)i];
			if (m <= 1e-9 || !std::isfinite(h[(size_t)i])) {
				continue;
			}

			// The transportable fraction thins as the pool runs down, so a slide tails off instead of
			// stopping dead when the last of it moves.
			const double frac = std::clamp(
					std::pow(std::clamp(m / p_depth_m, 0.0, 1.0), p_depth_exponent), 0.0, 1.0);
			const double budget = m * frac * p_amount;
			if (budget <= 1e-12) {
				continue;
			}

			double weight[8];
			double drop[8];
			double wsum = 0.0;
			int lower = 0;
			for (int k = 0; k < 8; k++) {
				weight[k] = 0.0;
				drop[k] = 0.0;
				const int nx = ix + SCATTER_DX[k];
				const int nz = iz + SCATTER_DZ[k];
				if (nx < 0 || nx >= p_gw || nz < 0 || nz >= p_gh) {
					continue;
				}
				const double hn = h[(size_t)(nz * p_gw + nx)];
				if (!std::isfinite(hn)) {
					continue; // NaN is the brush-loop mask: material does not flow into a hole in the world
				}
				// Only the part of the drop STEEPER than the angle of repose drives flow. Below it the
				// material has arrived and this is where deposition comes from — there is no separate
				// deposition rule, it is the absence of a driving slope.
				const double excess = (h[(size_t)i] - hn) - dist[k] * tan_repose;
				if (excess <= 0.0) {
					continue;
				}
				weight[k] = std::pow(excess / dist[k], p_viscosity_power);
				wsum += weight[k];
				drop[k] = h[(size_t)i] - hn;
				lower++;
			}
			if (lower == 0 || wsum <= 0.0) {
				continue;
			}

			const double move_total = budget * step_fraction;
			if (move_total <= 1e-12) {
				continue;
			}

			for (int k = 0; k < 8; k++) {
				if (weight[k] <= 0.0) {
					continue;
				}
				// This neighbour's share of the packet, but never more than half the drop to it: filling
				// a neighbour above this cell would reverse the local slope and the next sweep would send
				// the material straight back — a slide that oscillates instead of running out. A safety
				// net, not the transport law; at any reasonable grid the pool-driven share is smaller.
				const double give = std::min(move_total * (weight[k] / wsum), 0.5 * drop[k]);
				if (give <= 0.0) {
					continue;
				}
				rec.give[k] = give;
				rec.sent |= (uint8_t)(1u << k);
			}
		}
	};

	std::vector<double> next_h((size_t)n);
	std::vector<double> next_mobile((size_t)n);

	const auto gather_row = [&](int iz, const SlideRecord *p_above, const SlideRecord *p_row,
									const SlideRecord *p_below) {
		const SlideRecord *rows[3] = { p_above, p_row, p_below };
		for (int ix = 0; ix < p_gw; ix++) {
			// The serial sweep kept two accumulators, dh and dm, and fed them the SAME terms in the same
			// order, so they were always the same number. One does for both.
			double delta = 0.0;
			for (const ScatterSource &src : SCATTER_SOURCES) {
				const int sx = ix + src.dx;
				const SlideRecord *src_row = rows[src.dz + 1];
				if (!src_row || sx < 0 || sx >= p_gw) {
					continue;
				}
				const SlideRecord &rec = src_row[sx];
				if (src.k < 0) {
					// The cell's own gifts, in the order its neighbour loop gave them.
					for (int k = 0; k < 8; k++) {
						if (rec.sent & (1u << k)) {
							delta -= rec.give[k];
						}
					}
				} else if (rec.sent & (1u << src.k)) {
					delta += rec.give[src.k];
				}
			}
			const size_t i = (size_t)(iz * p_gw + ix);
			if (std::isfinite(h[i])) {
				next_h[i] = h[i] + delta;
				next_mobile[i] = std::max(0.0, mobile[i] + delta);
			} else {
				next_h[i] = h[i];
				next_mobile[i] = mobile[i];
			}
		}
	};

	for (int sweep = 0; sweep < sweeps; sweep++) {
		parallel_scatter_rows<SlideRecord>(p_gw, p_gh, compute_row, gather_row);
		h.swap(next_h);
		mobile.swap(next_mobile);
	}

	out.resize(n);
	float *dst = out.ptrw();
	double hi = 0.0;
	for (int i = 0; i < n; i++) {
		dst[i] = std::isfinite(h[(size_t)i]) ? (float)h[(size_t)i] : src[i];
		if (std::isfinite(h[(size_t)i])) {
			hi = std::max(hi, std::abs(h[(size_t)i] - (double)src[i]));
		}
	}

	if (r_deposition) {
		// Normalised, like SmoothFill's. A 0..1 channel is meaningless without the metres it was divided
		// by, so the divisor is returned rather than printed.
		const double divisor = (hi > 1e-12) ? hi : 1.0;
		if (r_deposition_divisor) {
			*r_deposition_divisor = divisor;
		}
		r_deposition->resize(n);
		float *dep = r_deposition->ptrw();
		for (int i = 0; i < n; i++) {
			dep[i] = std::isfinite(h[(size_t)i])
					? (float)((h[(size_t)i] - (double)src[i]) / divisor)
					: src[i];
		}
	}
	return out;
}
