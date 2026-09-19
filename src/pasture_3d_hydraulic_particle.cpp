// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_hydraulic_particle.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <vector>

using namespace godot;

HydraulicParticleParams HydraulicParticleParams::from_dict(const Dictionary &p_dict) {
	HydraulicParticleParams p;
	if (p_dict.has("droplet_count")) {
		p.droplet_count = std::max(1, (int)p_dict["droplet_count"]);
	}
	if (p_dict.has("max_lifetime")) {
		p.max_lifetime = std::max(1, (int)p_dict["max_lifetime"]);
	}
	if (p_dict.has("inertia")) {
		p.inertia = std::clamp((double)p_dict["inertia"], 0.0, 1.0);
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
	if (p_dict.has("evaporation_rate")) {
		p.evaporation_rate = std::clamp((double)p_dict["evaporation_rate"], 0.0, 1.0);
	}
	if (p_dict.has("min_slope")) {
		p.min_slope = std::max(0.0001, (double)p_dict["min_slope"]);
	}
	if (p_dict.has("gravity")) {
		p.gravity = std::max(0.1, (double)p_dict["gravity"]);
	}
	if (p_dict.has("bedrock_gap")) {
		p.bedrock_gap = std::max(0.0, (double)p_dict["bedrock_gap"]);
	}
	if (p_dict.has("ridge_forcing")) {
		p.ridge_forcing = std::max(0.0, (double)p_dict["ridge_forcing"]);
	}
	if (p_dict.has("seed")) {
		p.seed = (int64_t)p_dict["seed"];
	}
	if (p_dict.has("units")) {
		p.units = std::clamp((int)p_dict["units"], 0, 1);
	}
	if (p_dict.has("radius_m")) {
		p.radius_m = std::max(0.0, (double)p_dict["radius_m"]);
	}
	if (p_dict.has("step_length_m")) {
		p.step_length_m = std::max(0.01, (double)p_dict["step_length_m"]);
	}
	if (p_dict.has("droplet_density")) {
		p.droplet_density = std::max(0.0, (double)p_dict["droplet_density"]);
	}
	if (p_dict.has("deposit_at_death")) {
		p.deposit_at_death = (bool)p_dict["deposit_at_death"];
	}
	if (p_dict.has("mask")) {
		p.mask = p_dict["mask"];
	}
	return p;
}

Dictionary HydraulicParticleResult::to_dict() const {
	Dictionary d;
	d["ok"] = ok;
	d["height"] = height;
	d["eroded"] = eroded;
	d["deposited"] = deposited;
	d["flow"] = flow;
	return d;
}

// Accumulate in double and round once on the store, as the GDScript oracle does when it adds a 64-bit
// float to a PackedFloat32Array element. `float += (float)x` rounds twice, and the droplets amplify that
// last-bit difference into metres (GraphHydraulicParticleGate [A3]).
static inline void add_rounded(float &r_cell, double p_amount) {
	r_cell = (float)((double)r_cell + p_amount);
}

static inline double next_rand(uint32_t &p_state) {
	p_state = p_state * 1664525u + 1013904223u;
	return (double)p_state / 4294967296.0;
}

namespace {

// Where one step's erosion or deposition lands: the four bilinear corners, or a disc of cells.
struct Footprint {
	std::vector<int> idx;
	std::vector<double> w; // sums to 1
};

// Beyer's erosion brush: every finite cell within R metres of the droplet, weighted by (R - distance) and
// normalised to 1. Raster order, so the oracle (which walks the same box the same way) sums identically.
// Returns false when no cell carries weight, and the caller falls back to the bilinear corners.
bool disc_footprint(const std::vector<float> &p_height, int p_gw, int p_gh, double p_px, double p_pz,
		double p_dx, double p_dz, double p_radius_m, Footprint &r_fp) {
	r_fp.idx.clear();
	r_fp.w.clear();
	const double rcx = p_radius_m / p_dx;
	const double rcz = p_radius_m / p_dz;
	const int x0 = std::max(0, (int)std::ceil(p_px - rcx));
	const int x1 = std::min(p_gw - 1, (int)std::floor(p_px + rcx));
	const int z0 = std::max(0, (int)std::ceil(p_pz - rcz));
	const int z1 = std::min(p_gh - 1, (int)std::floor(p_pz + rcz));
	double sum = 0.0;
	for (int z = z0; z <= z1; z++) {
		for (int x = x0; x <= x1; x++) {
			const int i = z * p_gw + x;
			if (!std::isfinite(p_height[i])) {
				continue;
			}
			const double ox = ((double)x - p_px) * p_dx;
			const double oz = ((double)z - p_pz) * p_dz;
			const double wt = p_radius_m - std::sqrt(ox * ox + oz * oz);
			if (wt > 0.0) {
				r_fp.idx.push_back(i);
				r_fp.w.push_back(wt);
				sum += wt;
			}
		}
	}
	if (sum <= 0.0) {
		return false;
	}
	for (double &wt : r_fp.w) {
		wt /= sum;
	}
	return true;
}

} // namespace

HydraulicParticleResult godot::hydraulic_particle_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const HydraulicParticleParams &p_params) {
	HydraulicParticleResult res;
	if (p_gw < 2 || p_gh < 2) {
		return res;
	}
	const int n = p_gw * p_gh;
	if (p_surface.size() != n) {
		return res;
	}

	const float *src_height = p_surface.ptr();
	std::vector<float> height(src_height, src_height + n);
	std::vector<float> original_height(src_height, src_height + n);
	std::vector<float> flow(n, 0.0f);

	const bool has_mask = (p_params.mask.size() == n);
	const float *mask_ptr = has_mask ? p_params.mask.ptr() : nullptr;

	// The LCG runs on the seed's low 32 bits, and a zero state is 1337. Both are decided on the 32-bit value,
	// so a seed whose low half is zero, and the lowered seed (which carries only the low half), agree.
	uint32_t rng_state = (uint32_t)p_params.seed;
	if (rng_state == 0) {
		rng_state = 1337;
	}

	const bool metric = p_params.units == HydraulicParticleParams::UNITS_METRIC;
	// Cell size in metres, size / count as the grid hydraulic solver takes it.
	const double cell_dx = std::max((double)p_rect.size.x / (double)p_gw, 1e-9);
	const double cell_dz = std::max((double)p_rect.size.y / (double)p_gh, 1e-9);
	// METRIC: a step is `step_length_m` metres whatever the grid, so the path, the height fall per step and
	// the lifetime are the same on every resolution. CELLS: a step is one cell, the original units.
	const double step_m = metric ? p_params.step_length_m : 1.0;
	const double step_cx = metric ? step_m / cell_dx : 1.0;
	const double step_cz = metric ? step_m / cell_dz : 1.0;
	// A step moves the height at a point by `amt`; the volume that stands for is amt * step^2. Spread over
	// cells of dx*dz, that is `scale` times amt per unit of weight. CELLS keeps 1, its original meaning.
	const double scale = metric ? (step_m * step_m) / (cell_dx * cell_dz) : 1.0;
	// The brush. CELLS: the erosion radius alone, 0 being the four bilinear corners. METRIC: never narrower
	// than a step, or a fine grid would take a whole step's volume on four cells; it lays deposits too.
	const double radius_m = metric ? std::max(p_params.radius_m, step_m) : p_params.radius_m;
	const bool disc_erode = radius_m >= std::min(cell_dx, cell_dz);
	const bool disc_deposit = metric && disc_erode;

	const int droplet_count = metric
			? std::max(1, (int)std::llround(p_params.droplet_density * (double)p_rect.size.x * (double)p_rect.size.y / 100.0))
			: p_params.droplet_count;
	const int max_lifetime = p_params.max_lifetime;
	const double inertia = (double)p_params.inertia;
	const double sediment_capacity = (double)p_params.sediment_capacity;
	const double erosion_speed = (double)p_params.erosion_speed;
	const double deposition_speed = (double)p_params.deposition_speed;
	const double evaporation_rate = (double)p_params.evaporation_rate;
	const double min_fall = metric ? (double)p_params.min_slope * step_m : (double)p_params.min_slope;
	const double gravity = (double)p_params.gravity;
	const double bedrock_gap = (double)p_params.bedrock_gap;
	const double ridge_forcing = (double)p_params.ridge_forcing;

	const double tau = 6.283185307179586;

	Footprint fp;

	// Lay `p_amt` (metres at the droplet at p_px, p_pz) over the disc, or the four bilinear corners given.
	const auto lay_at = [&](double p_px, double p_pz, int p_i00, int p_i10, int p_i01, int p_i11,
								double p_w00, double p_w10, double p_w01, double p_w11, double p_amt, bool p_disc) {
		const double a = p_amt * scale;
		if (p_disc && disc_footprint(height, p_gw, p_gh, p_px, p_pz, cell_dx, cell_dz, radius_m, fp)) {
			for (size_t k = 0; k < fp.idx.size(); k++) {
				add_rounded(height[fp.idx[k]], a * fp.w[k]);
			}
			return;
		}
		add_rounded(height[p_i00], a * p_w00);
		add_rounded(height[p_i10], a * p_w10);
		add_rounded(height[p_i01], a * p_w01);
		add_rounded(height[p_i11], a * p_w11);
	};

	for (int d = 0; d < droplet_count; d++) {
		// Spawn droplet randomly on domain
		double px = next_rand(rng_state) * (double)(p_gw - 1);
		double pz = next_rand(rng_state) * (double)(p_gh - 1);

		double dir_x = 0.0;
		double dir_z = 0.0;
		double speed = 1.0;
		double water = 1.0;
		double sed = 0.0;

		// Which way this droplet's ridge forcing deflects. The perpendicular is a fixed 90 degree rotation
		// of the gradient, so a single sign sends EVERY droplet the same way across the slope: measured on
		// a plane tilted in +x, the scar behind a symmetric bump drifted +0.27 cells off the fall line at
		// forcing 1.2 and -0.06 at 0. Drawing the sign per droplet keeps the deflection and removes the
		// drift. The draw is skipped when the forcing is off, so the default RNG stream is unchanged.
		const double ridge_sign = (ridge_forcing > 0.0 && next_rand(rng_state) < 0.5) ? -1.0 : 1.0;

		// A droplet born on a no-data cell, or where the mask is off, never runs. Without this it walked
		// out of the masked-off region and cut the unmasked one (GraphHydraulicParticleGate [A4]).
		const int init_idx = std::clamp((int)px, 0, p_gw - 1) + std::clamp((int)pz, 0, p_gh - 1) * p_gw;
		if (!std::isfinite(height[init_idx]) || (has_mask && mask_ptr[init_idx] <= 0.001f)) {
			continue;
		}

		for (int step = 0; step < max_lifetime; step++) {
			int ix = (int)std::floor(px);
			int iz = (int)std::floor(pz);
			if (ix < 0 || ix >= p_gw - 1 || iz < 0 || iz >= p_gh - 1) {
				break;
			}

			double u = px - (double)ix;
			double v = pz - (double)iz;

			int i00 = iz * p_gw + ix;
			int i10 = i00 + 1;
			int i01 = (iz + 1) * p_gw + ix;
			int i11 = i01 + 1;

			float h00 = height[i00];
			float h10 = height[i10];
			float h01 = height[i01];
			float h11 = height[i11];

			if (!std::isfinite(h00) || !std::isfinite(h10) || !std::isfinite(h01) || !std::isfinite(h11)) {
				break;
			}

			// Bilinear interpolation of current elevation and gradient
			double h_curr = (1.0 - u) * (1.0 - v) * (double)h00 + u * (1.0 - v) * (double)h10 +
					(1.0 - u) * v * (double)h01 + u * v * (double)h11;

			// Differences in double: a float32 subtraction here was the root of the oracle divergence.
			double gx = (1.0 - v) * ((double)h10 - (double)h00) + v * ((double)h11 - (double)h01);
			double gz = (1.0 - u) * ((double)h01 - (double)h00) + u * ((double)h11 - (double)h10);
			if (metric) {
				// Metres per metre, so inertia weighs the same slope the same on every grid.
				gx /= cell_dx;
				gz /= cell_dz;
			}

			// Cross-gradient deflection: pushes flow off the fall line so channels wander instead of running
			// straight down it. See ridge_sign above for why the direction is per droplet.
			if (ridge_forcing > 0.0) {
				double perp_x = -gz * ridge_forcing * 0.5 * ridge_sign;
				double perp_z = gx * ridge_forcing * 0.5 * ridge_sign;
				gx += perp_x;
				gz += perp_z;
			}

			// Direction with momentum
			dir_x = dir_x * inertia - gx * (1.0 - inertia);
			dir_z = dir_z * inertia - gz * (1.0 - inertia);

			double dir_len = std::sqrt(dir_x * dir_x + dir_z * dir_z);
			if (dir_len > 1.0e-6) {
				dir_x /= dir_len;
				dir_z /= dir_len;
			} else {
				double ang = next_rand(rng_state) * tau;
				dir_x = std::cos(ang);
				dir_z = std::sin(ang);
			}

			double next_px = px + (metric ? dir_x * step_cx : dir_x);
			double next_pz = pz + (metric ? dir_z * step_cz : dir_z);

			int next_ix = (int)std::floor(next_px);
			int next_iz = (int)std::floor(next_pz);
			if (next_ix < 0 || next_ix >= p_gw - 1 || next_iz < 0 || next_iz >= p_gh - 1) {
				break;
			}

			double next_u = next_px - (double)next_ix;
			double next_v = next_pz - (double)next_iz;

			int ni00 = next_iz * p_gw + next_ix;
			int ni10 = ni00 + 1;
			int ni01 = (next_iz + 1) * p_gw + next_ix;
			int ni11 = ni01 + 1;

			float nh00 = height[ni00];
			float nh10 = height[ni10];
			float nh01 = height[ni01];
			float nh11 = height[ni11];

			if (!std::isfinite(nh00) || !std::isfinite(nh10) || !std::isfinite(nh01) || !std::isfinite(nh11)) {
				break;
			}

			double h_next = (1.0 - next_u) * (1.0 - next_v) * (double)nh00 + next_u * (1.0 - next_v) * (double)nh10 +
					(1.0 - next_u) * next_v * (double)nh01 + next_u * next_v * (double)nh11;
			double delta_h = h_next - h_curr;

			double w00 = (1.0 - u) * (1.0 - v);
			double w10 = u * (1.0 - v);
			double w01 = (1.0 - u) * v;
			double w11 = u * v;

			double mask_val = 1.0;
			if (has_mask) {
				mask_val = w00 * (double)mask_ptr[i00] + w10 * (double)mask_ptr[i10] +
						w01 * (double)mask_ptr[i01] + w11 * (double)mask_ptr[i11];
			}

			// Lay `p_amt` (metres at the droplet) on the terrain over the chosen footprint. Erosion passes a
			// negative amount.
			const auto lay = [&](double p_amt, bool p_disc) {
				lay_at(px, pz, i00, i10, i01, i11, w00, w10, w01, w11, p_amt, p_disc);
			};

			if (delta_h > 0.0) {
				// Moving uphill into pit — deposit sediment
				double deposit_amt = std::min(sed, delta_h) * mask_val;
				sed -= deposit_amt;
				lay(deposit_amt, disc_deposit);
				break;
			} else {
				// Moving downhill: compute sediment transport capacity
				double c = std::max(-delta_h, min_fall) * speed * water * sediment_capacity;

				if (sed > c) {
					// Drop excess sediment
					double drop = (sed - c) * deposition_speed * mask_val;
					sed -= drop;
					lay(drop, disc_deposit);
				} else {
					// Erode bedrock with Hesiod Bedrock Floor protection
					double erode_amt = std::min((c - sed) * erosion_speed, -delta_h) * mask_val;

					if (bedrock_gap > 0.0) {
						// The most the footprint can give, as an amount at the droplet. CELLS keeps its original
						// rule, the weighted mean of the cells' room above the floor. METRIC takes the exact floor:
						// cell i moves by amt * scale * w_i, so amt may not exceed room_i / (scale * w_i) anywhere.
						// The weighted mean divided by `scale` tightened with resolution squared and made the
						// fine grid erode half as much (GraphHydraulicParticleGate [U]).
						const auto room = [&](int p_i) {
							return std::max(0.0, (double)height[p_i] - ((double)original_height[p_i] - bedrock_gap));
						};
						double max_allowed = 0.0;
						if (metric) {
							double lim = std::numeric_limits<double>::infinity();
							if (disc_erode && disc_footprint(height, p_gw, p_gh, px, pz, cell_dx, cell_dz, radius_m, fp)) {
								for (size_t k = 0; k < fp.idx.size(); k++) {
									lim = std::min(lim, room(fp.idx[k]) / (scale * fp.w[k]));
								}
							} else {
								const int ci[4] = { i00, i10, i01, i11 };
								const double cw[4] = { w00, w10, w01, w11 };
								for (int k = 0; k < 4; k++) {
									if (cw[k] > 0.0) {
										lim = std::min(lim, room(ci[k]) / (scale * cw[k]));
									}
								}
							}
							erode_amt = std::min(erode_amt, lim);
						} else if (disc_erode && disc_footprint(height, p_gw, p_gh, px, pz, cell_dx, cell_dz, radius_m, fp)) {
							for (size_t k = 0; k < fp.idx.size(); k++) {
								max_allowed += fp.w[k] * room(fp.idx[k]);
							}
							erode_amt = std::min(erode_amt, max_allowed);
						} else {
							double max_cut00 = std::max(0.0, (double)height[i00] - ((double)original_height[i00] - bedrock_gap));
							double max_cut10 = std::max(0.0, (double)height[i10] - ((double)original_height[i10] - bedrock_gap));
							double max_cut01 = std::max(0.0, (double)height[i01] - ((double)original_height[i01] - bedrock_gap));
							double max_cut11 = std::max(0.0, (double)height[i11] - ((double)original_height[i11] - bedrock_gap));
							max_allowed = w00 * max_cut00 + w10 * max_cut10 + w01 * max_cut01 + w11 * max_cut11;
							erode_amt = std::min(erode_amt, max_allowed);
						}
					}

					sed += erode_amt;
					lay(-erode_amt, disc_erode);
				}

				speed = std::sqrt(std::max(0.0, speed * speed + delta_h * -gravity));
				water *= (1.0 - evaporation_rate);

				add_rounded(flow[i00], (water * w00));
				add_rounded(flow[i10], (water * w10));
				add_rounded(flow[i01], (water * w01));
				add_rounded(flow[i11], (water * w11));

				px = next_px;
				pz = next_pz;
			}
		}

		// Death. Every way out of the step loop leaves (px, pz) where the droplet last stood, which was a valid
		// cell -- except a droplet that died at its first check -- so what it still carries lands there.
		// The mask scales it, as it scales every other deposit: masked-off terrain stays untouched.
		if (p_params.deposit_at_death && sed > 0.0) {
			const int ix = (int)std::floor(px);
			const int iz = (int)std::floor(pz);
			if (ix >= 0 && ix < p_gw - 1 && iz >= 0 && iz < p_gh - 1) {
				const int i00 = iz * p_gw + ix;
				const int i10 = i00 + 1;
				const int i01 = i00 + p_gw;
				const int i11 = i01 + 1;
				if (std::isfinite(height[i00]) && std::isfinite(height[i10]) && std::isfinite(height[i01]) && std::isfinite(height[i11])) {
					const double u = px - (double)ix;
					const double v = pz - (double)iz;
					const double w00 = (1.0 - u) * (1.0 - v);
					const double w10 = u * (1.0 - v);
					const double w01 = (1.0 - u) * v;
					const double w11 = u * v;
					double mask_val = 1.0;
					if (has_mask) {
						mask_val = w00 * (double)mask_ptr[i00] + w10 * (double)mask_ptr[i10] +
								w01 * (double)mask_ptr[i01] + w11 * (double)mask_ptr[i11];
					}
					lay_at(px, pz, i00, i10, i01, i11, w00, w10, w01, w11, sed * mask_val, disc_deposit);
				}
			}
		}
	}

	res.ok = true;
	res.height.resize(n);
	std::memcpy(res.height.ptrw(), height.data(), n * sizeof(float));

	// Net change against the input, in metres; no-data stays 0.
	res.eroded.resize(n);
	res.deposited.resize(n);
	float *out_e = res.eroded.ptrw();
	float *out_d = res.deposited.ptrw();
	for (int i = 0; i < n; i++) {
		const double change = (double)height[i] - (double)original_height[i];
		const bool ok = std::isfinite(change);
		out_e[i] = ok ? (float)std::max(0.0, -change) : 0.0f;
		out_d[i] = ok ? (float)std::max(0.0, change) : 0.0f;
	}

	// flow: the water-weighted visits times the step length is path length per cell; over the cell's area
	// and the rain's density (droplets per m^2), that is n * step / droplets, in metres.
	const double step_len = metric ? step_m : std::sqrt(cell_dx * cell_dz);
	const double flow_scale = (double)n * step_len / (double)std::max(droplet_count, 1);
	res.flow.resize(n);
	float *out_f = res.flow.ptrw();
	for (int i = 0; i < n; i++) {
		out_f[i] = (float)((double)flow[i] * flow_scale);
	}

	return res;
}
