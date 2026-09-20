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

// ---- PIPE: the virtual-pipe shallow-water model of Mei, Decaudin & Hu, "Fast Hydraulic Erosion Simulation
// and Visualization on GPU" (Pacific Graphics 2007), written from the paper. Every length is metres and
// every rate is per second of simulated time, so the same world at a different resolution solves the same
// water: that is the point of it (review item 8), and what the Musgrave model above cannot do.
//
// Each substep is three gathers, each reading only start-of-phase buffers and writing only its own cell,
// so no split of the rows can change a bit (no scatter, no replay):
//   A. flux     each cell's four outflow pipes accelerate with the surface difference, and are scaled
//               down together so they cannot drain more than the cell holds;
//   B. water    net inflow updates the depth; the net flux through the cell gives the velocity; the
//               velocity and the ground tilt give a carrying capacity, and the cell erodes or deposits
//               toward it;
//   C. carry    sediment is advected semi-Lagrangian: each cell takes what sat upstream along -v*dt.
// Rain and evaporation are per iteration, as in the Musgrave model, so rain_rate means the same thing.
namespace {

constexpr double PIPE_G = 9.81;
// The pipes' cross-section is (the cell side they cross) x PIPE_DEPTH, so the flux per metre of cell side
// is independent of the cell size -- the resolution-invariant choice. It also sets the wave speed that
// bounds the substep.
constexpr double PIPE_DEPTH = 1.0;
constexpr double PIPE_MIN_DEPTH = 1e-4; // below this a cell has no velocity

} // namespace

static void pipe_solve(const float *p_src, int p_gw, int p_gh, const Rect2 &p_rect, const ErosionHydraulicParams &p_params,
		std::vector<float> &r_height, std::vector<float> &r_sediment, std::vector<float> &r_flow) {
	const int n = p_gw * p_gh;
	std::vector<float> &height = r_height;
	std::vector<float> &sediment = r_sediment;
	std::vector<float> &flow = r_flow;
	std::vector<float> water(n, 0.0f);
	std::vector<float> flux[4];
	for (int k = 0; k < 4; k++) {
		flux[k].assign(n, 0.0f);
	}
	std::vector<float> vel_x(n, 0.0f);
	std::vector<float> vel_z(n, 0.0f);
	std::vector<float> sed_mid(n, 0.0f);
	std::vector<float> next_height(n);
	std::vector<float> next_water(n);

	const double dx = (double)p_rect.size.x / (double)p_gw;
	const double dz = (double)p_rect.size.y / (double)p_gh;
	const double area = dx * dz;
	const double len[4] = { dx, dx, dz, dz };
	const double side[4] = { dz, dz, dx, dx };
	const bool outlets = p_params.edge_mode == ErosionHydraulicParams::EDGE_OUTLETS;
	const double p_outlet = p_params.outlet_level;
	const double p_rain = p_params.rain_rate;
	const double p_evap = p_params.evaporation_rate;
	const double p_cap = p_params.sediment_capacity;
	const double p_min_slope = p_params.min_slope;

	const double dt_max = 0.25 * std::min(dx, dz) / std::sqrt(PIPE_G * PIPE_DEPTH);
	const int substeps = std::max(1, (int)std::ceil(p_params.time_step / dt_max));
	const double dt = p_params.time_step / (double)substeps;
	const double k_ero = std::min(1.0, p_params.erosion_speed * dt);
	const double k_dep = std::min(1.0, p_params.deposition_speed * dt);

	const auto finite_at = [&](int x, int z) {
		return x >= 0 && x < p_gw && z >= 0 && z < p_gh && std::isfinite(height[z * p_gw + x]);
	};

	for (int pass = 0; pass < p_params.iterations; pass++) {
		for (int i = 0; i < n; i++) {
			if (std::isfinite(height[i])) {
				water[i] = (float)((double)water[i] + p_rain);
			}
		}

		for (int sub = 0; sub < substeps; sub++) {
			// A. flux
			Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int p_z0, int p_z1) {
				for (int iz = p_z0; iz < p_z1; iz++) {
					for (int ix = 0; ix < p_gw; ix++) {
						const int i = iz * p_gw + ix;
						const double b = (double)height[i];
						if (!std::isfinite(b)) {
							for (int k = 0; k < 4; k++) {
								flux[k][i] = 0.0f;
							}
							continue;
						}
						const double surf = b + (double)water[i];
						double f[4];
						double total = 0.0;
						for (int k = 0; k < 4; k++) {
							const int nx = ix + SCATTER_DX[k];
							const int nz = iz + SCATTER_DZ[k];
							double n_surf;
							if (finite_at(nx, nz)) {
								const int ni = nz * p_gw + nx;
								n_surf = (double)height[ni] + (double)water[ni];
							} else if (outlets) {
								n_surf = (double)p_src[i] - p_outlet;
							} else {
								f[k] = 0.0;
								continue;
							}
							f[k] = std::max(0.0, (double)flux[k][i] + dt * PIPE_G * side[k] * PIPE_DEPTH * (surf - n_surf) / len[k]);
							total += f[k];
						}
						const double volume = (double)water[i] * area;
						if (total * dt > volume && total > 0.0) {
							const double scale = volume / (total * dt);
							for (int k = 0; k < 4; k++) {
								f[k] = f[k] * scale;
							}
						}
						for (int k = 0; k < 4; k++) {
							flux[k][i] = (float)f[k];
						}
					}
				}
			});

			// B. water, velocity, erosion and deposition
			Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int p_z0, int p_z1) {
				for (int iz = p_z0; iz < p_z1; iz++) {
					for (int ix = 0; ix < p_gw; ix++) {
						const int i = iz * p_gw + ix;
						const double b = (double)height[i];
						if (!std::isfinite(b)) {
							next_height[i] = height[i];
							next_water[i] = water[i];
							sed_mid[i] = sediment[i];
							vel_x[i] = 0.0f;
							vel_z[i] = 0.0f;
							continue;
						}
						// What each neighbour sends this way: its pipe pointing back at this cell (k ^ 1).
						double in[4] = { 0.0, 0.0, 0.0, 0.0 };
						double b_n[4];
						for (int k = 0; k < 4; k++) {
							const int nx = ix + SCATTER_DX[k];
							const int nz = iz + SCATTER_DZ[k];
							if (finite_at(nx, nz)) {
								const int ni = nz * p_gw + nx;
								in[k] = (double)flux[k ^ 1][ni];
								b_n[k] = (double)height[ni];
							} else {
								b_n[k] = b;
							}
						}
						const double out[4] = { (double)flux[0][i], (double)flux[1][i], (double)flux[2][i], (double)flux[3][i] };
						const double w0 = (double)water[i];
						const double net = (in[0] + in[1] + in[2] + in[3]) - (out[0] + out[1] + out[2] + out[3]);
						const double w1 = std::max(0.0, w0 + dt * net / area);
						const double depth = 0.5 * (w0 + w1);
						double u = 0.0;
						double v = 0.0;
						if (depth > PIPE_MIN_DEPTH) {
							u = 0.5 * (in[0] - out[0] + out[1] - in[1]) / (dz * depth);
							v = 0.5 * (in[2] - out[2] + out[3] - in[3]) / (dx * depth);
						}
						const double gx = (b_n[1] - b_n[0]) / (2.0 * dx);
						const double gz = (b_n[3] - b_n[2]) / (2.0 * dz);
						const double grad2 = gx * gx + gz * gz;
						const double tilt = std::max(std::sqrt(grad2 / (1.0 + grad2)), p_min_slope);
						const double speed = std::sqrt(u * u + v * v);
						const double cap = p_cap * tilt * speed * w1;
						double s = (double)sediment[i];
						double b1 = b;
						if (cap > s) {
							const double amt = k_ero * (cap - s);
							b1 = b - amt;
							s = s + amt;
						} else {
							const double amt = k_dep * (s - cap);
							b1 = b + amt;
							s = s - amt;
						}
						// Neighbours read this cell's ground (the tilt) and water in this phase: write aside.
						next_height[i] = (float)b1;
						next_water[i] = (float)w1;
						sed_mid[i] = (float)s;
						vel_x[i] = (float)u;
						vel_z[i] = (float)v;
						flow[i] = (float)((double)flow[i] + speed * w1 * dt);
					}
				}
			});
			height.swap(next_height);
			water.swap(next_water);

			// C. carry: bilinear sample of sed_mid at the upstream point, in cell units, clamped to the grid.
			// A tap on no-data would carry nothing real, so such a cell keeps its own sediment.
			Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int p_z0, int p_z1) {
				for (int iz = p_z0; iz < p_z1; iz++) {
					for (int ix = 0; ix < p_gw; ix++) {
						const int i = iz * p_gw + ix;
						if (!std::isfinite(height[i])) {
							sediment[i] = sed_mid[i];
							continue;
						}
						const double x = std::clamp((double)ix - (double)vel_x[i] * dt / dx, 0.0, (double)(p_gw - 1));
						const double z = std::clamp((double)iz - (double)vel_z[i] * dt / dz, 0.0, (double)(p_gh - 1));
						const int x0 = (int)std::floor(x);
						const int z0 = (int)std::floor(z);
						const int x1 = std::min(x0 + 1, p_gw - 1);
						const int z1 = std::min(z0 + 1, p_gh - 1);
						const int t00 = z0 * p_gw + x0;
						const int t10 = z0 * p_gw + x1;
						const int t01 = z1 * p_gw + x0;
						const int t11 = z1 * p_gw + x1;
						if (!std::isfinite(height[t00]) || !std::isfinite(height[t10]) || !std::isfinite(height[t01]) || !std::isfinite(height[t11])) {
							sediment[i] = sed_mid[i];
							continue;
						}
						const double fx = x - (double)x0;
						const double fz = z - (double)z0;
						const double top = (double)sed_mid[t00] * (1.0 - fx) + (double)sed_mid[t10] * fx;
						const double bot = (double)sed_mid[t01] * (1.0 - fx) + (double)sed_mid[t11] * fx;
						sediment[i] = (float)(top * (1.0 - fz) + bot * fz);
					}
				}
			});
		}

		for (int i = 0; i < n; i++) {
			if (std::isfinite(height[i])) {
				water[i] = (float)((double)water[i] * (1.0 - p_evap));
			}
		}
	}
}

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
	if (p_dict.has("edge_mode")) {
		p.edge_mode = std::clamp((int)p_dict["edge_mode"], 0, 1);
	}
	if (p_dict.has("outlet_level")) {
		p.outlet_level = std::max(0.0, (double)p_dict["outlet_level"]);
	}
	if (p_dict.has("model")) {
		p.model = std::clamp((int)p_dict["model"], 0, 1);
	}
	if (p_dict.has("settle_at_end")) {
		p.settle_at_end = (bool)p_dict["settle_at_end"];
	}
	if (p_dict.has("time_step")) {
		p.time_step = std::max(1e-3, (double)p_dict["time_step"]);
	}
	return p;
}

Dictionary ErosionHydraulicResult::to_dict() const {
	Dictionary d;
	d["ok"] = ok;
	d["height"] = height;
	d["eroded"] = eroded;
	d["deposited"] = deposited;
	d["flow"] = flow;
	return d;
}

// 4. The output channels. See the header: settle, net change, and the flow accumulator in its unit.
ErosionHydraulicResult godot::erosion_hydraulic_finish(const PackedFloat32Array &p_input,
		PackedFloat32Array &r_height, const PackedFloat32Array &p_sediment, const PackedFloat32Array &p_flow_accum,
		int p_gw, int p_gh, const Rect2 &p_rect, const ErosionHydraulicParams &p_params) {
	ErosionHydraulicResult res;
	const int n = p_gw * p_gh;
	if (p_input.size() != n || r_height.size() != n || p_sediment.size() != n || p_flow_accum.size() != n) {
		return res;
	}
	const float *in_ptr = p_input.ptr();
	float *h_ptr = r_height.ptrw();
	const float *s_ptr = p_sediment.ptr();
	const float *f_ptr = p_flow_accum.ptr();

	if (p_params.settle_at_end) {
		for (int i = 0; i < n; i++) {
			if (std::isfinite(h_ptr[i])) {
				h_ptr[i] = (float)((double)h_ptr[i] + (double)s_ptr[i]);
			}
		}
	}

	// MUSGRAVE's accumulator is metres of rain that passed through, summed over passes: divided by the rain
	// per pass and the pass count that is a count of contributing cells, and times the cell area, m^2.
	// PIPE's is speed * depth * dt summed, so over the simulated time and times the cell width it is m^3/s.
	const double cell_dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double cell_dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	double flow_scale = 1.0;
	if (p_params.model == ErosionHydraulicParams::MODEL_PIPE) {
		const double total_time = std::max(1e-9, (double)p_params.iterations * p_params.time_step);
		flow_scale = std::sqrt(cell_dx * cell_dz) / total_time;
	} else if (p_params.rain_rate > 0.0) {
		flow_scale = cell_dx * cell_dz / (p_params.rain_rate * (double)std::max(p_params.iterations, 1));
	}

	res.height = r_height;
	res.eroded.resize(n);
	res.deposited.resize(n);
	res.flow.resize(n);
	float *out_e = res.eroded.ptrw();
	float *out_d = res.deposited.ptrw();
	float *out_f = res.flow.ptrw();
	for (int i = 0; i < n; i++) {
		const double change = (double)h_ptr[i] - (double)in_ptr[i];
		if (std::isfinite(change)) {
			out_e[i] = (float)std::max(0.0, -change);
			out_d[i] = (float)std::max(0.0, change);
			out_f[i] = (float)((double)f_ptr[i] * flow_scale);
		} else {
			out_e[i] = 0.0f;
			out_d[i] = 0.0f;
			out_f[i] = 0.0f;
		}
	}
	res.ok = true;
	return res;
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
	const auto to_channels = [&]() {
		PackedFloat32Array h;
		PackedFloat32Array s;
		PackedFloat32Array f;
		h.resize(n);
		s.resize(n);
		f.resize(n);
		std::memcpy(h.ptrw(), height.data(), n * sizeof(float));
		std::memcpy(s.ptrw(), sediment.data(), n * sizeof(float));
		std::memcpy(f.ptrw(), flow_accum.data(), n * sizeof(float));
		return erosion_hydraulic_finish(p_surface, h, s, f, p_gw, p_gh, p_rect, p_params);
	};
	if (p_params.model == ErosionHydraulicParams::MODEL_PIPE) {
		pipe_solve(src_height, p_gw, p_gh, p_rect, p_params, height, sediment, flow_accum);
		return to_channels();
	}
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
	const bool outlets = p_params.edge_mode == ErosionHydraulicParams::EDGE_OUTLETS;
	const double p_outlet = p_params.outlet_level;

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
				// The neighbour's water surface; an edge or no-data neighbour has one only under OUTLETS.
				double n_total = 0.0;
				bool has_surface = false;
				if (nx >= 0 && nx < p_gw && nz >= 0 && nz < p_gh && std::isfinite(height[nz * p_gw + nx])) {
					const int ni = nz * p_gw + nx;
					n_total = (double)height[ni] + (double)water[ni];
					has_surface = true;
				} else if (outlets) {
					n_total = (double)src_height[i] - p_outlet;
					has_surface = true;
				}
				if (has_surface) {
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

	return to_channels();
}
