// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_hydraulic_saleve.h"
#include "pasture_3d_thread_pool.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <numeric>
#include <queue>
#include <vector>

using namespace godot;

namespace {

inline float fast_hash_to_unit(uint32_t seed, uint32_t key) {
	uint32_t n = seed ^ (key * 0x5bd1e995);
	n = (n ^ (n >> 13)) * 0x5bd1e995;
	n ^= n >> 15;
	return ((float)(n & 0x00ffffff) / 8388608.0f) - 1.0f; // [-1.0 .. 1.0]
}

// Smoothstep-interpolated value noise on the integer lattice, in [-1, 1]. Mirrored by the GDScript oracle.
double saleve_value_noise(double p_x, double p_z, uint32_t p_seed) {
	const double fx = std::floor(p_x);
	const double fz = std::floor(p_z);
	const int32_t ix = (int32_t)fx;
	const int32_t iz = (int32_t)fz;
	auto corner = [&](int32_t cx, int32_t cz) -> double {
		const uint32_t key = ((uint32_t)cx * 73856093u) ^ ((uint32_t)cz * 19349663u);
		return (double)fast_hash_to_unit(p_seed, key);
	};
	double tx = p_x - fx;
	double tz = p_z - fz;
	tx = tx * tx * (3.0 - 2.0 * tx);
	tz = tz * tz * (3.0 - 2.0 * tz);
	const double a = corner(ix, iz) + (corner(ix + 1, iz) - corner(ix, iz)) * tx;
	const double b = corner(ix, iz + 1) + (corner(ix + 1, iz + 1) - corner(ix, iz + 1)) * tx;
	return a + (b - a) * tz;
}

// Radial cubic pulse: 1 at the centre, 0 from r = 1 out.
double saleve_pulse(double p_r) {
	return p_r < 1.0 ? 1.0 - p_r * p_r * (3.0 - 2.0 * p_r) : 0.0;
}

} // namespace

HydraulicSaleveParams HydraulicSaleveParams::from_dict(const Dictionary &p_dict) {
	HydraulicSaleveParams p;
	if (p_dict.has("iterations")) {
		p.iterations = std::max(1, (int)p_dict["iterations"]);
	}
	if (p_dict.has("erosion_strength")) {
		p.erosion_strength = std::clamp((float)p_dict["erosion_strength"], 0.0f, 1.0f);
	} else if (p_dict.has("incision_rate")) {
		p.erosion_strength = std::clamp((float)p_dict["incision_rate"], 0.0f, 1.0f);
	}
	if (p_dict.has("drainage_exponent")) {
		p.drainage_exponent = std::clamp((float)p_dict["drainage_exponent"], 0.01f, 0.8f);
	}
	if (p_dict.has("drainage_noise")) {
		p.drainage_noise = std::max(0.0f, (float)p_dict["drainage_noise"]);
	}
	if (p_dict.has("tolerance")) {
		p.tolerance = std::max(0.0f, (float)p_dict["tolerance"]);
	}
	if (p_dict.has("max_slope_center")) {
		p.max_slope_center = std::max(0.0f, (float)p_dict["max_slope_center"]);
	}
	if (p_dict.has("max_slope_border")) {
		p.max_slope_border = std::max(0.0f, (float)p_dict["max_slope_border"]);
	}
	if (p_dict.has("reroute_lakes")) {
		p.reroute_lakes = (bool)p_dict["reroute_lakes"];
	}
	if (p_dict.has("stable_noise")) {
		p.stable_noise = (bool)p_dict["stable_noise"];
	}
	if (p_dict.has("debug_network")) {
		p.debug_network = (bool)p_dict["debug_network"];
	}
	if (p_dict.has("shape_preservation")) {
		p.shape_preservation = std::clamp((float)p_dict["shape_preservation"], 0.1f, 4.0f);
	}
	if (p_dict.has("bank_smoothing")) {
		p.bank_smoothing = std::clamp((float)p_dict["bank_smoothing"], 0.0f, 0.5f);
	}
	if (p_dict.has("seed")) {
		p.seed = (int)p_dict["seed"];
	}
	if (p_dict.has("mask")) {
		p.mask = p_dict["mask"];
	}
	if (p_dict.has("dx")) {
		p.dx = p_dict["dx"];
	}
	if (p_dict.has("dy")) {
		p.dy = p_dict["dy"];
	}
	if (p_dict.has("reference_relief")) {
		p.reference_relief = std::max(0.0f, (float)p_dict["reference_relief"]);
	}
	if (p_dict.has("deposition_radius")) {
		p.deposition_radius = std::max(0.0f, (float)p_dict["deposition_radius"]);
	}
	if (p_dict.has("deposition_strength")) {
		p.deposition_strength = std::clamp((float)p_dict["deposition_strength"], 0.0f, 1.0f);
	}
	if (p_dict.has("stream_strength")) {
		p.stream_strength = std::clamp((float)p_dict["stream_strength"], 0.0f, 1.0f);
	}
	if (p_dict.has("stream_exp")) {
		p.stream_exp = std::clamp((float)p_dict["stream_exp"], 0.01f, 1.0f);
	}
	if (p_dict.has("enable_post_smoothing")) {
		p.enable_post_smoothing = (bool)p_dict["enable_post_smoothing"];
	}
	return p;
}

Dictionary HydraulicSaleveResult::to_dict() const {
	Dictionary d;
	d["ok"] = ok;
	d["height"] = height;
	d["eroded_rock"] = eroded_rock;
	d["sediment"] = sediment;
	d["iterations"] = iterations;
	d["cell_area"] = cell_area;
	if (!receivers.is_empty()) {
		d["receivers"] = receivers;
		d["drainage_area"] = drainage_area;
	}
	return d;
}

HydraulicSaleveResult godot::hydraulic_saleve_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const HydraulicSaleveParams &p_params) {
	HydraulicSaleveResult res;
	if (p_gw < 2 || p_gh < 2) {
		return res;
	}
	const int n = p_gw * p_gh;
	if (p_surface.size() != n) {
		return res;
	}

	const float *src_height = p_surface.ptr();
	const bool has_mask = (p_params.mask.size() == n);
	const float *mask_ptr = has_mask ? p_params.mask.ptr() : nullptr;
	const bool has_dx = (p_params.dx.size() == n);
	const bool has_dy = (p_params.dy.size() == n);
	const float *dx_ptr = has_dx ? p_params.dx.ptr() : nullptr;
	const float *dy_ptr = has_dy ? p_params.dy.ptr() : nullptr;

	float zmin = std::numeric_limits<float>::max();
	float zmax = -std::numeric_limits<float>::max();
	for (int i = 0; i < n; i++) {
		float h = src_height[i];
		if (std::isfinite(h)) {
			if (h < zmin) zmin = h;
			if (h > zmax) zmax = h;
		}
	}

	if (zmax - zmin < 1.0e-5f) {
		res.ok = true;
		res.height = p_surface.duplicate();
		res.eroded_rock.resize(n);
		res.eroded_rock.fill(0.0f);
		res.sediment.resize(n);
		res.sediment.fill(0.0f);
		return res;
	}

	const float zptp = zmax - zmin;

	// ---- THE SOLVER'S UNIT OF LENGTH -------------------------------------------------------------
	//
	// This is a shape solver: it works on a unit-elevation field and is remapped back to metres at the
	// end, so its horizontal scale has to be expressed in the SAME unit as its vertical one or the
	// aspect ratio it erodes at is not the terrain's. It used to take dx = 1/gw — "one cell is one grid
	// fraction" — which makes every slope, drainage distance and chi integral a function of how many
	// cells the caller happened to ask for. Widen the grid (a brush's Modifier Margin does exactly
	// that, without moving one vertex of the shape) and the whole drainage network rescales against the
	// landform it is cutting.
	//
	// Now: cell size in metres from the world rect, divided by the vertical reference. Slopes are true
	// dimensionless gradients (max_slope 4.0 == 76 degrees), and gw/gh do not enter any length. What
	// remains extent-dependent is the reference itself when it is left on auto — pin `reference_relief`
	// to make the node invariant to margins and footprint edits alike.
	const float relief_ref = (p_params.reference_relief > 0.0f) ? p_params.reference_relief : zptp;
	const double cell_dx = (p_rect.size.x > 0.0f) ? ((double)p_rect.size.x / (double)std::max(p_gw, 1)) : 1.0;
	const double cell_dz = (p_rect.size.y > 0.0f) ? ((double)p_rect.size.y / (double)std::max(p_gh, 1)) : 1.0;

	// Normalized unit elevation [0..1]
	std::vector<float> z(n);
	std::vector<float> erodibility(n, 1.0f);
	// uint8_t, not bool: std::vector<bool> packs cells into shared words, so two rows each writing only
	// their own cells would still race on the word between them.
	std::vector<uint8_t> is_outlet(n, 0);

	// Per cell: the normalised height, the erodibility pow and the outlet flag read only the cell's own
	// input, so the rows split exactly.
	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				int idx = iz * p_gw + ix;
				float h = src_height[idx];
				if (!std::isfinite(h)) {
					z[idx] = 0.0f;
					is_outlet[idx] = 1;
					continue;
				}
				float zn = (h - zmin) / zptp;
				z[idx] = zn;

				// Hesiod Shape Preservation: erodibility = (1.0 - z_norm)^shape_exp. Measured against the
				// reference relief, so a pinned reference keeps a given height eroding at a given rate.
				const float zr = (h - zmin) / std::max(relief_ref, 1.0e-5f);
				erodibility[idx] = std::pow(std::clamp(1.0f - zr, 0.01f, 1.0f), p_params.shape_preservation);

				// Border cells are default outlets
				if (ix == 0 || ix == p_gw - 1 || iz == 0 || iz == p_gh - 1) {
					is_outlet[idx] = 1;
				}
			}
		}
	});

	const int iterations = std::max(1, p_params.iterations);
	const float m_exp = p_params.drainage_exponent;
	const float noise_strength = p_params.drainage_noise;
	const uint32_t seed = (uint32_t)p_params.seed;

	// Cell size in units of the vertical reference (see above): metres / metres, so it is the same unit
	// the unit-elevation field is in and gw/gh cancel out of it entirely.
	const double vref = (double)std::max(relief_ref, 1.0e-5f);
	const double dx = cell_dx / vref;
	const double dz = cell_dz / vref;
	const double diag_dist = std::sqrt(dx * dx + dz * dz);
	// Drainage area in the same squared unit, so accumulation is an area on the ground rather than a
	// count of however many cells the caller asked for.
	const double cell_area = dx * dz;

	// ---- THE DRAINAGE GRAPH ----------------------------------------------------------------------
	//
	// Stage 1 never indexes the grid directly: it walks vertices, their neighbour lists and the edge
	// lengths between them. Here that graph is the 8-connected grid; phase S2 of the fidelity spec swaps
	// in a triangulation of jittered control points without touching the solver.
	const int n_dx[8] = { -1, 1, 0, 0, -1, 1, -1, 1 };
	const int n_dz[8] = { 0, 0, -1, 1, -1, -1, 1, 1 };
	const double n_dist[8] = { dx, dx, dz, dz, diag_dist, diag_dist, diag_dist, diag_dist };
	std::vector<int> nbr_start(n + 1);
	std::vector<int> nbr;
	std::vector<double> nbr_len;
	std::vector<int8_t> nbr_dir; // index into n_dx/n_dz, for the dx/dy routing warp
	nbr.reserve((size_t)n * 8);
	nbr_len.reserve((size_t)n * 8);
	nbr_dir.reserve((size_t)n * 8);
	for (int idx = 0; idx < n; idx++) {
		nbr_start[idx] = (int)nbr.size();
		const int ix = idx % p_gw;
		const int iz = idx / p_gw;
		for (int k = 0; k < 8; k++) {
			const int nx = ix + n_dx[k];
			const int nz = iz + n_dz[k];
			if (nx >= 0 && nx < p_gw && nz >= 0 && nz < p_gh) {
				nbr.push_back(nz * p_gw + nx);
				nbr_len.push_back(n_dist[k]);
				nbr_dir.push_back((int8_t)k);
			}
		}
	}
	nbr_start[n] = (int)nbr.size();
	auto edge_len = [&](int a, int b) -> double {
		for (int e = nbr_start[a]; e < nbr_start[a + 1]; e++) {
			if (nbr[e] == b) {
				return nbr_len[e];
			}
		}
		return 1.0e-5;
	};

	// ---- Break flats -----------------------------------------------------------------------------
	// A plateau has no steepest neighbour, so every cell on it is a pit. 1e-3 of the unit relief of
	// low-frequency value noise, on a fixed 50 m world lattice (not a grid fraction, so a margin does not
	// move it), tilts it enough to route across. The working copy only; the output never sees it.
	{
		const double lattice = 50.0;
		const uint32_t fseed = seed ^ 0x9e3779b9u;
		for (int idx = 0; idx < n; idx++) {
			if (!std::isfinite(src_height[idx])) {
				continue;
			}
			const double wx = (double)p_rect.position.x + ((idx % p_gw) + 0.5) * cell_dx;
			const double wz = (double)p_rect.position.y + ((idx / p_gw) + 0.5) * cell_dz;
			z[idx] += (float)(1.0e-3 * saleve_value_noise(wx / lattice, wz / lattice, fseed));
		}
	}

	// ---- Radial slope limit (dimensionless m/m, converted to unit elevation per unit length) -----
	std::vector<float> slope_cap(n);
	{
		const double cx = (double)p_rect.position.x + 0.5 * cell_dx * p_gw;
		const double cz = (double)p_rect.position.y + 0.5 * cell_dz * p_gh;
		const double side = std::max(std::min(cell_dx * p_gw, cell_dz * p_gh), 1.0e-6);
		const double to_unit = vref / (double)zptp;
		for (int idx = 0; idx < n; idx++) {
			const double wx = (double)p_rect.position.x + ((idx % p_gw) + 0.5) * cell_dx;
			const double wz = (double)p_rect.position.y + ((idx / p_gw) + 0.5) * cell_dz;
			const double r = std::sqrt((wx - cx) * (wx - cx) + (wz - cz) * (wz - cz)) / side;
			const double pulse = saleve_pulse(r);
			const double s = p_params.max_slope_border + (p_params.max_slope_center - p_params.max_slope_border) * pulse;
			slope_cap[idx] = (float)(s * to_unit);
		}
	}

	std::vector<int> receivers(n);
	std::vector<float> area_acc(n, 0.0f);
	std::vector<float> response_times(n, 0.0f);
	std::vector<int> order;
	order.reserve(n);
	std::vector<int> root_of(n);
	std::vector<int> child_start(n + 1);
	std::vector<int> child_fill(n);
	std::vector<int> children(n);

	// Children lists from `receivers`, then a breadth-first walk out of every root (a vertex that is its
	// own receiver), in index order. `order` is outlet -> leaves; `root_of` names each vertex's terminal.
	auto build_tree = [&]() {
		std::fill(child_start.begin(), child_start.end(), 0);
		for (int i = 0; i < n; i++) {
			if (receivers[i] != i) {
				child_start[receivers[i] + 1]++;
			}
		}
		for (int i = 0; i < n; i++) {
			child_start[i + 1] += child_start[i];
		}
		std::copy(child_start.begin(), child_start.begin() + n, child_fill.begin());
		for (int i = 0; i < n; i++) {
			if (receivers[i] != i) {
				children[child_fill[receivers[i]]++] = i;
			}
		}
		order.clear();
		for (int i = 0; i < n; i++) {
			if (receivers[i] == i) {
				order.push_back(i);
				root_of[i] = i;
			}
		}
		for (size_t head = 0; head < order.size(); head++) {
			const int v = order[head];
			for (int c = child_start[v]; c < child_start[v + 1]; c++) {
				const int ch = children[c];
				root_of[ch] = root_of[v];
				order.push_back(ch);
			}
		}
	};

	// ================================================================================================
	// Stage 1: Steady-State Fluvial Incision (Chi-Transform LEM with dx/dy perturbation)
	// ================================================================================================
	int iters_done = 0;
	std::vector<uint8_t> basin_drained(n);
	std::vector<uint8_t> settled(n);
	std::vector<double> dist(n);
	std::vector<int> pred(n);
	for (int iter = 0; iter < iterations; iter++) {
		iters_done = iter + 1;
		// The routing noise is a pure hash of (seed, cell pair): the same every pass, so the network can
		// settle. Hashing the pass number in as well (the old behaviour, `stable_noise` off) re-rolls every
		// channel choice each pass and the solve never converges.
		const uint32_t pass_seed = p_params.stable_noise ? seed : seed + (uint32_t)iter * 17;

		// 1. Steepest descent receivers with routing noise / dx/dy perturbation. A vertex scores its
		// neighbours off `z` and writes only its own receiver, so the rows split exactly.
		Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
			for (int idx = z0 * p_gw; idx < z1 * p_gw; idx++) {
				if (is_outlet[idx]) {
					receivers[idx] = idx;
					continue;
				}
				const float z_c = z[idx];
				float best_score = -1.0e9f;
				int best = idx;
				for (int e = nbr_start[idx]; e < nbr_start[idx + 1]; e++) {
					const int n_idx = nbr[e];
					const float dz_val = z_c - z[n_idx];
					if (dz_val > 0.0f) {
						const float slope = dz_val / (float)nbr_len[e];
						const float noise = fast_hash_to_unit(pass_seed, (uint32_t)(idx ^ (n_idx << 16)));
						float warp_factor = 1.0f;
						// EITHER axis on its own is a real warp: a missing component is a ZERO component.
						if (dx_ptr || dy_ptr) {
							const int k = nbr_dir[e];
							const float wdx = dx_ptr ? dx_ptr[idx] : 0.0f;
							const float wdy = dy_ptr ? dy_ptr[idx] : 0.0f;
							warp_factor += 0.5f * (wdx * (float)n_dx[k] + wdy * (float)n_dz[k]);
						}
						const float score = slope * (warp_factor + noise_strength * noise);
						if (score > best_score) {
							best_score = score;
							best = n_idx;
						}
					}
				}
				receivers[idx] = best;
			}
		});

		build_tree();

		// 2. Lake rerouting. A pit is a root that is not an outlet: its whole basin drains nowhere, and the
		// network fragments into inward bowls. A shortest-path search (ground distance) grows outward from
		// the outlets; the first time it steps into an undrained basin, the receiver chain from that vertex
		// down to the pit is reversed so the basin spills into the vertex the search arrived from. That
		// vertex was settled first, so it already drains to an outlet, and so does everything behind it.
		// Ties break on (distance, index), so the result is independent of heap internals.
		bool any_pit = false;
		for (int i = 0; i < n; i++) {
			basin_drained[i] = is_outlet[i];
			if (receivers[i] == i && !is_outlet[i]) {
				any_pit = true;
			}
		}
		if (any_pit && p_params.reroute_lakes) {
			using Entry = std::pair<double, int>;
			std::priority_queue<Entry, std::vector<Entry>, std::greater<Entry>> heap;
			std::fill(settled.begin(), settled.end(), 0);
			std::fill(dist.begin(), dist.end(), std::numeric_limits<double>::infinity());
			std::fill(pred.begin(), pred.end(), -1);
			for (int i = 0; i < n; i++) {
				if (is_outlet[i]) {
					dist[i] = 0.0;
					heap.push({ 0.0, i });
				}
			}
			while (!heap.empty()) {
				const Entry top = heap.top();
				heap.pop();
				const int c = top.second;
				if (settled[c]) {
					continue;
				}
				settled[c] = 1;
				if (!basin_drained[root_of[c]]) {
					int prev = pred[c];
					int cur = c;
					while (true) {
						const int nxt = receivers[cur];
						receivers[cur] = prev;
						if (nxt == cur) {
							break;
						}
						prev = cur;
						cur = nxt;
					}
					basin_drained[root_of[c]] = 1;
				}
				for (int e = nbr_start[c]; e < nbr_start[c + 1]; e++) {
					const int j = nbr[e];
					const double nd = top.first + nbr_len[e];
					if (!settled[j] && nd < dist[j]) {
						dist[j] = nd;
						pred[j] = c;
						heap.push({ nd, j });
					}
				}
			}
			build_tree();
		}

		// 3. Accumulate drainage area, leaves -> outlet.
		std::fill(area_acc.begin(), area_acc.end(), (float)cell_area);
		for (int k = n - 1; k >= 0; k--) {
			const int idx = order[k];
			const int r = receivers[idx];
			if (r != idx) {
				area_acc[r] += area_acc[idx];
			}
		}

		// 4. Response times (the chi integral), outlet -> leaves.
		for (int k = 0; k < n; k++) {
			const int idx = order[k];
			const int r = receivers[idx];
			if (r == idx) {
				response_times[idx] = 0.0f;
				continue;
			}
			const float d = std::max((float)edge_len(idx, r), 1.0e-5f);
			const float celerity = erodibility[idx] * std::pow(std::max(area_acc[idx], (float)cell_area), m_exp);
			response_times[idx] = response_times[r] + (d / std::max(celerity, 1.0e-4f));
		}

		// 5. Steady-state heights, outlet -> leaves: the outlet's height plus the response time, then held
		// under the radial slope cap against the (already updated) receiver.
		float diff = 0.0f;
		for (int k = 0; k < n; k++) {
			const int idx = order[k];
			const int r = receivers[idx];
			if (r == idx) {
				continue;
			}
			float new_z = z[root_of[idx]] + response_times[idx];
			const float d = std::max((float)edge_len(idx, r), 1.0e-5f);
			const float cap = z[r] + slope_cap[idx] * d;
			if (new_z > cap) {
				new_z = cap;
			}
			diff += std::abs(new_z - z[idx]);
			z[idx] = new_z;
		}

		float zlo = std::numeric_limits<float>::max();
		float zhi = -std::numeric_limits<float>::max();
		for (int i = 0; i < n; i++) {
			zlo = std::min(zlo, z[i]);
			zhi = std::max(zhi, z[i]);
		}
		if (diff / (float)n < p_params.tolerance * std::max(zhi - zlo, 1.0e-5f)) {
			break;
		}
	}
	res.iterations = iters_done;
	res.cell_area = (float)cell_area;
	if (p_params.debug_network) {
		res.receivers.resize(n);
		res.drainage_area.resize(n);
		for (int i = 0; i < n; i++) {
			res.receivers.set(i, receivers[i]);
			res.drainage_area.set(i, area_acc[i]);
		}
	}

	// Remap Stage 1 back to [0..1]
	float ze_min = std::numeric_limits<float>::max();
	float ze_max = -std::numeric_limits<float>::max();
	for (int i = 0; i < n; i++) {
		if (z[i] < ze_min) ze_min = z[i];
		if (z[i] > ze_max) ze_max = z[i];
	}
	float ze_span = std::max(ze_max - ze_min, 1.0e-5f);
	for (int i = 0; i < n; i++) {
		z[i] = (z[i] - ze_min) / ze_span;
	}

	// ================================================================================================
	// Stage 2: Sediment Deposition (Deposition / Alluvial Flats)
	// ================================================================================================
	std::vector<float> sediment(n, 0.0f);
	if (p_params.deposition_strength > 0.0f && p_params.deposition_radius > 0.0f) {
		// Radius in METRES converted to cells, not a fraction of the grid: the alluvial flat is a size on
		// the ground, so it must not grow when the solved extent does.
		const double cell_m = std::max(std::min(cell_dx, cell_dz), 1.0e-4);
		int ir = std::max(1, (int)std::lround((double)p_params.deposition_radius / cell_m));
		ir = std::min(ir, std::max(1, std::min(p_gw, p_gh) / 2));
		std::vector<float> z_fill = z;

		// Morphological depression smoothing to fill valley floors
		for (int iz = 0; iz < p_gh; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				int idx = iz * p_gw + ix;
				float max_n = z_fill[idx];
				for (int dy_i = -ir; dy_i <= ir; dy_i++) {
					int ny = iz + dy_i;
					if (ny < 0 || ny >= p_gh) continue;
					for (int dx_i = -ir; dx_i <= ir; dx_i++) {
						int nx = ix + dx_i;
						if (nx < 0 || nx >= p_gw) continue;
						if (dx_i * dx_i + dy_i * dy_i <= ir * ir) {
							max_n = std::max(max_n, z_fill[ny * p_gw + nx]);
						}
					}
				}
				z_fill[idx] = 0.5f * (z_fill[idx] + max_n);
			}
		}

		for (int i = 0; i < n; i++) {
			float diff = std::max(0.0f, z_fill[i] - z[i]);
			float dep = p_params.deposition_strength * diff;
			z[i] += dep;
			sediment[i] = dep * relief_ref;
		}
	}

	// ================================================================================================
	// Stage 3: Fine River Channel Incision (HydraulicStreamLog secondary pass)
	// ================================================================================================
	if (p_params.stream_strength > 0.0f) {
		// Upstream first: `order` is outlet -> leaves, so walk it backwards.
		for (int k = n - 1; k >= 0; k--) {
			const int idx = order[k];
			int r = receivers[idx];
			if (r != idx) {
				int ix = idx % p_gw;
				int iz = idx / p_gw;
				int rx = r % p_gw;
				int rz = r / p_gw;
				float d = (float)std::sqrt(std::pow((ix - rx) * dx, 2.0) + std::pow((iz - rz) * dz, 2.0));
				float slope = std::max(0.0f, (z[idx] - z[r]) / std::max(d, 1.0e-5f));
				float stream_inc = p_params.stream_strength * std::log(1.0f + std::pow(std::max(area_acc[idx], (float)cell_area), p_params.stream_exp) * slope) * erodibility[idx] * 0.15f;
				z[idx] = std::max(z[r], z[idx] - stream_inc);
			}
		}
	}

	// ================================================================================================
	// Stage 4: Post-Processing
	// ================================================================================================
	if (p_params.enable_post_smoothing || p_params.bank_smoothing > 0.0f) {
		std::vector<float> smoothed = z;
		float blend = p_params.enable_post_smoothing ? 0.3f : (p_params.bank_smoothing * 0.4f);
		// Reads z, writes smoothed: the rows split exactly.
		Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
			for (int iz = std::max(z0, 1); iz < std::min(z1, p_gh - 1); iz++) {
				for (int ix = 1; ix < p_gw - 1; ix++) {
					int idx = iz * p_gw + ix;
					float avg = 0.25f * (z[iz * p_gw + ix - 1] + z[iz * p_gw + ix + 1] +
							z[(iz - 1) * p_gw + ix] + z[(iz + 1) * p_gw + ix]);
					smoothed[idx] = (1.0f - blend) * z[idx] + blend * avg;
				}
			}
		});
		z = smoothed;
	}

	// 5. Final Composite with original heightfield in world metres
	std::vector<float> final_height(n);
	std::vector<float> eroded_rock(n, 0.0f);

	// Per cell: each output reads only its own input height, mask and eroded height.
	Pasture3DThreadPool::parallel_for_elements(n, 4096, [&](int i0, int i1) {
		for (int i = i0; i < i1; i++) {
			float orig_h = src_height[i];
			if (!std::isfinite(orig_h)) {
				final_height[i] = orig_h;
				eroded_rock[i] = 0.0f;
				continue;
			}

			// Stage 1 renormalised the field to [0..1], so the amplitude out is the REFERENCE, anchored at the
			// input's low point — not "whatever range happened to be in the grid". On auto these are the same
			// number; pinned, it is what stops a margin band's surrounding terrain from stretching the landform.
			float eroded_h = zmin + z[i] * relief_ref;
			float m_val = has_mask ? mask_ptr[i] : 1.0f;
			float eff_weight = p_params.erosion_strength * m_val;

			float res_h = (1.0f - eff_weight) * orig_h + eff_weight * eroded_h;
			final_height[i] = res_h;
			eroded_rock[i] = std::max(0.0f, orig_h - res_h);
		}
	});

	res.ok = true;
	res.height.resize(n);
	std::memcpy(res.height.ptrw(), final_height.data(), n * sizeof(float));

	res.eroded_rock.resize(n);
	std::memcpy(res.eroded_rock.ptrw(), eroded_rock.data(), n * sizeof(float));

	res.sediment.resize(n);
	std::memcpy(res.sediment.ptrw(), sediment.data(), n * sizeof(float));

	return res;
}
