// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_hydraulic_saleve.h"
#include "pasture_3d_hydraulic_stream_log.h"
#include "pasture_3d_thread_pool.h"

#include <godot_cpp/classes/geometry2d.hpp>

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
	if (p_dict.has("rim_width")) {
		p.rim_width = std::max(0.0f, (float)p_dict["rim_width"]);
	}
	if (p_dict.has("outlet_level")) {
		p.outlet_level = std::max(0.0f, (float)p_dict["outlet_level"]);
	}
	if (p_dict.has("flat_from_fill")) {
		p.flat_from_fill = (bool)p_dict["flat_from_fill"];
	}
	if (p_dict.has("cap_everywhere")) {
		p.cap_everywhere = (bool)p_dict["cap_everywhere"];
	}
	if (p_dict.has("lower_only")) {
		p.lower_only = (bool)p_dict["lower_only"];
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
	if (p_dict.has("control_points")) {
		p.control_points = std::clamp((int)p_dict["control_points"], 16, 1000000);
	}
	if (p_dict.has("point_spacing")) {
		p.point_spacing = std::max(0.0f, (float)p_dict["point_spacing"]);
	}
	if (p_dict.has("reconstruction")) {
		p.reconstruction = std::clamp((int)p_dict["reconstruction"], 0, 2);
	}
	if (p_dict.has("default_warp")) {
		p.default_warp = (bool)p_dict["default_warp"];
	}
	if (p_dict.has("warp_amount")) {
		p.warp_amount = std::max(0.0f, (float)p_dict["warp_amount"]);
	}
	if (p_dict.has("warp_size")) {
		p.warp_size = std::max(0.0f, (float)p_dict["warp_size"]);
	}
	if (p_dict.has("grid_solve")) {
		p.grid_solve = (bool)p_dict["grid_solve"];
	}
	if (p_dict.has("skip_stage1")) {
		p.skip_stage1 = (bool)p_dict["skip_stage1"];
	}
	if (p_dict.has("debug_stages")) {
		p.debug_stages = (bool)p_dict["debug_stages"];
	}
	if (p_dict.has("reconstruct_only")) {
		p.reconstruct_only = (bool)p_dict["reconstruct_only"];
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
	d["vertex_count"] = vertex_count;
	if (!pre_stream.is_empty()) {
		d["pre_stream"] = pre_stream;
		d["post_stream"] = post_stream;
		d["deposition"] = deposition;
	}
	if (!vertices.is_empty()) {
		d["vertices"] = vertices;
	}
	if (!receivers.is_empty()) {
		d["receivers"] = receivers;
		d["drainage_area"] = drainage_area;
	}
	return d;
}


namespace {

// The drainage graph Stage 1 runs on: vertices at world positions, neighbour lists with edge lengths in
// reference-relief units, and a ground area per vertex in the same squared unit.
struct SaleveGraph {
	int nv = 0;
	std::vector<double> px; // world metres
	std::vector<double> pz;
	std::vector<int> nbr_start;
	std::vector<int> nbr;
	std::vector<double> nbr_len;
	std::vector<double> area;
	std::vector<uint8_t> outlet;
	// Mesh only: triangles (vertex triples) for reconstruction.
	std::vector<int> tris;
};

double saleve_edge_len(const SaleveGraph &g, int a, int b) {
	for (int e = g.nbr_start[a]; e < g.nbr_start[a + 1]; e++) {
		if (g.nbr[e] == b) {
			return g.nbr_len[e];
		}
	}
	return 1.0e-5;
}

// Bilinear sample of the input at a world position, cell centres at (i + 0.5) * cell. NaN if any tap is.
double saleve_sample(const float *h, int gw, int gh, double x0, double z0, double cdx, double cdz, double x, double z) {
	// Extrapolates across the half cell between the outermost centres and the rect edge, where the boundary
	// ring sits: clamping there would bend a plane.
	double gx = std::clamp((x - x0) / cdx - 0.5, -0.5, (double)gw - 0.5);
	double gz = std::clamp((z - z0) / cdz - 0.5, -0.5, (double)gh - 0.5);
	int ix = std::clamp((int)std::floor(gx), 0, gw - 2);
	int iz = std::clamp((int)std::floor(gz), 0, gh - 2);
	double tx = gx - ix;
	double tz = gz - iz;
	double a = h[iz * gw + ix], b = h[iz * gw + ix + 1];
	double c = h[(iz + 1) * gw + ix], d = h[(iz + 1) * gw + ix + 1];
	double top = a + (b - a) * tx;
	double bot = c + (d - c) * tx;
	return top + (bot - top) * tz;
}

double saleve_fbm(double x, double z, uint32_t seed) {
	double sum = 0.0, amp = 1.0, norm = 0.0, f = 1.0;
	for (int o = 0; o < 4; o++) {
		sum += amp * saleve_value_noise(x * f, z * f, seed + (uint32_t)o * 101u);
		norm += amp;
		amp *= 0.5;
		f *= 2.0;
	}
	return sum / norm;
}

struct SaleveStage1 {
	std::vector<int> receivers;
	std::vector<int> order; // outlet -> leaves
	std::vector<int> root_of;
	std::vector<float> area_acc;
	int iterations = 0;
};

// Stage 1: steady-state fluvial incision over any drainage graph (S1 of the fidelity spec).
void saleve_stage1(const SaleveGraph &g, std::vector<float> &z, const std::vector<float> &erodibility,
		const std::vector<float> &slope_cap, const HydraulicSaleveParams &p_params, SaleveStage1 &r_out) {
	const int n = g.nv;
	const int iterations = std::max(1, p_params.iterations);
	const float m_exp = p_params.drainage_exponent;
	const float noise_strength = p_params.drainage_noise;
	const uint32_t seed = (uint32_t)p_params.seed;

	std::vector<int> &receivers = r_out.receivers;
	std::vector<int> &order = r_out.order;
	std::vector<int> &root_of = r_out.root_of;
	std::vector<float> &area_acc = r_out.area_acc;
	receivers.assign(n, 0);
	root_of.assign(n, 0);
	area_acc.assign(n, 0.0f);
	order.reserve(n);
	std::vector<float> response_times(n, 0.0f);
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

	std::vector<uint8_t> basin_drained(n);
	std::vector<uint8_t> settled(n);
	std::vector<double> dist(n);
	std::vector<int> pred(n);
	for (int iter = 0; iter < iterations; iter++) {
		r_out.iterations = iter + 1;
		// The routing noise is a pure hash of (seed, vertex pair): the same every pass, so the network can
		// settle. `stable_noise` off re-rolls it every pass (the old behaviour; it never converges).
		const uint32_t pass_seed = p_params.stable_noise ? seed : seed + (uint32_t)iter * 17;

		// 1. Steepest descent receivers with routing noise. Each vertex writes only its own receiver.
		Pasture3DThreadPool::parallel_for_elements(n, 1024, [&](int i0, int i1) {
			for (int idx = i0; idx < i1; idx++) {
				if (g.outlet[idx]) {
					receivers[idx] = idx;
					continue;
				}
				const float z_c = z[idx];
				float best_score = -1.0e9f;
				int best = idx;
				for (int e = g.nbr_start[idx]; e < g.nbr_start[idx + 1]; e++) {
					const int n_idx = g.nbr[e];
					const float dz_val = z_c - z[n_idx];
					if (dz_val > 0.0f) {
						const float slope = dz_val / (float)g.nbr_len[e];
						const float noise = fast_hash_to_unit(pass_seed, (uint32_t)(idx ^ (n_idx << 16)));
						const float score = slope * (1.0f + noise_strength * noise);
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

		// 2. Lake rerouting. A shortest-path search (ground distance) grows outward from the outlets; the
		// first time it steps into an undrained basin, the receiver chain from that vertex down to the pit
		// is reversed so the basin spills into the vertex the search arrived from, which already drains.
		// Ties break on (distance, index), so the result is independent of heap internals.
		bool any_pit = false;
		for (int i = 0; i < n; i++) {
			basin_drained[i] = g.outlet[i];
			if (receivers[i] == i && !g.outlet[i]) {
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
				if (g.outlet[i]) {
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
				for (int e = g.nbr_start[c]; e < g.nbr_start[c + 1]; e++) {
					const int j = g.nbr[e];
					const double nd = top.first + g.nbr_len[e];
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
		for (int i = 0; i < n; i++) {
			area_acc[i] = (float)g.area[i];
		}
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
			const float d = std::max((float)saleve_edge_len(g, idx, r), 1.0e-5f);
			const float celerity = erodibility[idx] * std::pow(std::max(area_acc[idx], (float)g.area[idx]), m_exp);
			response_times[idx] = response_times[r] + (d / std::max(celerity, 1.0e-4f));
		}

		// 5. Steady-state heights, outlet -> leaves, held under the radial slope cap against the receiver.
		float diff = 0.0f;
		for (int k = 0; k < n; k++) {
			const int idx = order[k];
			const int r = receivers[idx];
			if (r == idx) {
				continue;
			}
			float new_z = z[root_of[idx]] + response_times[idx];
			const float d = std::max((float)saleve_edge_len(g, idx, r), 1.0e-5f);
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
}

} // namespace



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
	const float *dx_ptr = (p_params.dx.size() == n) ? p_params.dx.ptr() : nullptr;
	const float *dy_ptr = (p_params.dy.size() == n) ? p_params.dy.ptr() : nullptr;

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
	// end, so its horizontal scale is expressed in the same unit as its vertical one: metres divided by
	// the vertical reference. Slopes are true dimensionless gradients and gw/gh enter no length. What
	// remains extent-dependent is the reference itself when it is left on auto — pin `reference_relief`
	// to make the node invariant to margins and footprint edits alike.
	const float relief_ref = (p_params.reference_relief > 0.0f) ? p_params.reference_relief : zptp;
	const double vref = (double)std::max(relief_ref, 1.0e-5f);
	const double x0 = p_rect.position.x;
	const double z0 = p_rect.position.y;
	const double rw = (p_rect.size.x > 0.0f) ? (double)p_rect.size.x : (double)p_gw;
	const double rh = (p_rect.size.y > 0.0f) ? (double)p_rect.size.y : (double)p_gh;
	const double cell_dx = rw / (double)p_gw;
	const double cell_dz = rh / (double)p_gh;
	const double min_side = std::min(rw, rh);

	// ---- THE DRAINAGE GRAPH ----------------------------------------------------------------------
	SaleveGraph g;
	std::vector<double> vh; // input height at each vertex, metres (NaN outside the data)
	const bool mesh = !p_params.grid_solve;
	if (!mesh) {
		// The 8-connected grid, vertex == cell (the S1 solver; kept as a gate control).
		g.nv = n;
		g.px.resize(n);
		g.pz.resize(n);
		g.outlet.assign(n, 0);
		g.area.assign(n, (cell_dx / vref) * (cell_dz / vref));
		vh.resize(n);
		const int n_dx[8] = { -1, 1, 0, 0, -1, 1, -1, 1 };
		const int n_dz[8] = { 0, 0, -1, 1, -1, -1, 1, 1 };
		const double ddx = cell_dx / vref, ddz = cell_dz / vref;
		const double diag = std::sqrt(ddx * ddx + ddz * ddz);
		const double n_dist[8] = { ddx, ddx, ddz, ddz, diag, diag, diag, diag };
		g.nbr_start.resize(n + 1);
		for (int idx = 0; idx < n; idx++) {
			const int ix = idx % p_gw;
			const int iz = idx / p_gw;
			g.px[idx] = x0 + (ix + 0.5) * cell_dx;
			g.pz[idx] = z0 + (iz + 0.5) * cell_dz;
			vh[idx] = src_height[idx];
			g.outlet[idx] = (ix == 0 || iz == 0 || ix == p_gw - 1 || iz == p_gh - 1) ? 1 : 0;
			g.nbr_start[idx] = (int)g.nbr.size();
			for (int k = 0; k < 8; k++) {
				const int nx = ix + n_dx[k];
				const int nz = iz + n_dz[k];
				if (nx >= 0 && nx < p_gw && nz >= 0 && nz < p_gh) {
					g.nbr.push_back(nz * p_gw + nx);
					g.nbr_len.push_back(n_dist[k]);
				}
			}
		}
		g.nbr_start[n] = (int)g.nbr.size();
	} else {
		// Jittered control points (S2). One point per cell of a WORLD-anchored lattice of pitch `s`, so a
		// pinned `point_spacing` holds every interior point in place when the rect grows; a boundary ring
		// at pitch ~s along the rect's edges (corners included) is the outlet set.
		double s = (p_params.point_spacing > 0.0f) ? (double)p_params.point_spacing
												   : std::sqrt(rw * rh / (double)std::max(p_params.control_points, 16));
		s = std::max(s, std::max(cell_dx, cell_dz));
		std::vector<float> fx, fz; // float positions: the exact values the triangulation sees
		std::vector<uint8_t> ring;
		auto add = [&](double x, double z, bool b) {
			fx.push_back((float)x);
			fz.push_back((float)z);
			ring.push_back(b ? 1 : 0);
		};
		const int ex = std::max(1, (int)std::lround(rw / s));
		const int ez = std::max(1, (int)std::lround(rh / s));
		for (int k = 0; k <= ex; k++) {
			add(x0 + rw * k / ex, z0, true);
			add(x0 + rw * k / ex, z0 + rh, true);
		}
		for (int k = 1; k < ez; k++) {
			add(x0, z0 + rh * k / ez, true);
			add(x0 + rw, z0 + rh * k / ez, true);
		}
		const uint32_t jseed = (uint32_t)p_params.seed ^ 0x51ed27u;
		const int32_t i_lo = (int32_t)std::floor(x0 / s), i_hi = (int32_t)std::floor((x0 + rw) / s);
		const int32_t j_lo = (int32_t)std::floor(z0 / s), j_hi = (int32_t)std::floor((z0 + rh) / s);
		const double inset = 0.4 * s;
		for (int32_t j = j_lo; j <= j_hi; j++) {
			for (int32_t i = i_lo; i <= i_hi; i++) {
				const uint32_t key = ((uint32_t)i * 73856093u) ^ ((uint32_t)j * 19349663u);
				const double jx = 0.35 * fast_hash_to_unit(jseed, key);
				const double jz = 0.35 * fast_hash_to_unit(jseed + 1u, key);
				const double x = (i + 0.5 + jx) * s;
				const double z = (j + 0.5 + jz) * s;
				if (x > x0 + inset && x < x0 + rw - inset && z > z0 + inset && z < z0 + rh - inset) {
					add(x, z, false);
				}
			}
		}
		const int nv = (int)fx.size();
		PackedVector2Array pts;
		pts.resize(nv);
		for (int i = 0; i < nv; i++) {
			pts.set(i, Vector2(fx[i], fz[i]));
		}
		const PackedInt32Array tri = Geometry2D::get_singleton()->triangulate_delaunay(pts);
		g.nv = nv;
		g.px.resize(nv);
		g.pz.resize(nv);
		g.outlet.assign(nv, 0);
		g.area.assign(nv, 0.0);
		vh.resize(nv);
		for (int i = 0; i < nv; i++) {
			g.px[i] = (double)fx[i];
			g.pz[i] = (double)fz[i];
			g.outlet[i] = ring[i];
			vh[i] = saleve_sample(src_height, p_gw, p_gh, x0, z0, cell_dx, cell_dz, g.px[i], g.pz[i]);
		}
		std::vector<std::vector<int>> adj(nv);
		const int nt = tri.size() / 3;
		g.tris.reserve((size_t)nt * 3);
		for (int t = 0; t < nt; t++) {
			const int a = tri[t * 3], b = tri[t * 3 + 1], c = tri[t * 3 + 2];
			const double ar = 0.5 * std::abs((g.px[b] - g.px[a]) * (g.pz[c] - g.pz[a]) - (g.px[c] - g.px[a]) * (g.pz[b] - g.pz[a]));
			if (ar < 1.0e-9 * s * s) {
				continue; // a sliver along the collinear boundary ring carries no area and no useful edge
			}
			g.tris.push_back(a);
			g.tris.push_back(b);
			g.tris.push_back(c);
			const double third = ar / 3.0 / (vref * vref);
			g.area[a] += third;
			g.area[b] += third;
			g.area[c] += third;
			adj[a].push_back(b);
			adj[a].push_back(c);
			adj[b].push_back(a);
			adj[b].push_back(c);
			adj[c].push_back(a);
			adj[c].push_back(b);
		}
		g.nbr_start.resize(nv + 1);
		for (int i = 0; i < nv; i++) {
			std::sort(adj[i].begin(), adj[i].end());
			adj[i].erase(std::unique(adj[i].begin(), adj[i].end()), adj[i].end());
			g.nbr_start[i] = (int)g.nbr.size();
			for (int j : adj[i]) {
				g.nbr.push_back(j);
				const double ddx = g.px[j] - g.px[i], ddz = g.pz[j] - g.pz[i];
				g.nbr_len.push_back(std::sqrt(ddx * ddx + ddz * ddz) / vref);
			}
		}
		g.nbr_start[nv] = (int)g.nbr.size();
	}
	const int nv = g.nv;
	res.vertex_count = nv;

	// Normalised unit elevation per vertex, erodibility, and NaN vertices become outlets.
	std::vector<float> z(nv);
	std::vector<float> erodibility(nv, 1.0f);
	for (int i = 0; i < nv; i++) {
		const double h = vh[i];
		if (!std::isfinite(h)) {
			z[i] = 0.0f;
			g.outlet[i] = 1;
			continue;
		}
		z[i] = (float)((h - zmin) / zptp);
		if (p_params.outlet_level > 0.0f && z[i] <= p_params.outlet_level) {
			g.outlet[i] = 1;
		}
		// Hesiod Shape Preservation: erodibility = (1 - z_ref)^shape_exp against the reference relief.
		const float zr = (float)((h - zmin) / std::max(relief_ref, 1.0e-5f));
		erodibility[i] = std::pow(std::clamp(1.0f - zr, 0.01f, 1.0f), p_params.shape_preservation);
	}

	SaleveStage1 st;
	if (!p_params.reconstruct_only && !p_params.skip_stage1) {
		const uint32_t seed = (uint32_t)p_params.seed;
		// Break flats: 1e-3 of the unit relief of value noise on a fixed 50 m world lattice. Working copy only.
		const uint32_t fseed = seed ^ 0x9e3779b9u;
		for (int i = 0; i < nv; i++) {
			if (std::isfinite(vh[i])) {
				z[i] += (float)(1.0e-3 * saleve_value_noise(g.px[i] / 50.0, g.pz[i] / 50.0, fseed));
			}
		}
		// Radial slope cap (dimensionless m/m) in unit elevation per unit length.
		std::vector<float> slope_cap(nv);
		const double cx = x0 + 0.5 * rw, cz = z0 + 0.5 * rh;
		const double to_unit = vref / (double)zptp;
		for (int i = 0; i < nv; i++) {
			const double r = std::sqrt((g.px[i] - cx) * (g.px[i] - cx) + (g.pz[i] - cz) * (g.pz[i] - cz)) / std::max(min_side, 1.0e-6);
			const double sl = p_params.max_slope_border + (p_params.max_slope_center - p_params.max_slope_border) * saleve_pulse(r);
			slope_cap[i] = (float)(sl * to_unit);
		}

		saleve_stage1(g, z, erodibility, slope_cap, p_params, st);
		res.iterations = st.iterations;

		// Remap Stage 1 back to [0..1].
		float lo = std::numeric_limits<float>::max();
		float hi = -std::numeric_limits<float>::max();
		for (int i = 0; i < nv; i++) {
			lo = std::min(lo, z[i]);
			hi = std::max(hi, z[i]);
		}
		const float span = std::max(hi - lo, 1.0e-5f);
		for (int i = 0; i < nv; i++) {
			z[i] = (z[i] - lo) / span;
		}
	}
	if (p_params.debug_network) {
		res.cell_area = (float)((cell_dx / vref) * (cell_dz / vref));
		res.vertices.resize(nv);
		for (int i = 0; i < nv; i++) {
			res.vertices.set(i, Vector2((real_t)g.px[i], (real_t)g.pz[i]));
		}
		if (!st.receivers.empty()) {
			res.receivers.resize(nv);
			res.drainage_area.resize(nv);
			for (int i = 0; i < nv; i++) {
				res.receivers.set(i, st.receivers[i]);
				res.drainage_area.set(i, st.area_acc[i]);
			}
		}
	}

	// ---- RECONSTRUCTION onto the grid ------------------------------------------------------------
	std::vector<float> zg(n);
	if (!mesh) {
		std::copy(z.begin(), z.end(), zg.begin());
	} else {
		// Per-vertex gradient (unit elevation per metre): least squares over the neighbours, 1/len^2 weights.
		std::vector<double> gx(nv, 0.0), gz(nv, 0.0);
		if (p_params.reconstruction == 1) {
			for (int i = 0; i < nv; i++) {
				double sxx = 0, sxz = 0, szz = 0, sx = 0, sz = 0;
				for (int e = g.nbr_start[i]; e < g.nbr_start[i + 1]; e++) {
					const int j = g.nbr[e];
					const double ex_ = g.px[j] - g.px[i], ez_ = g.pz[j] - g.pz[i];
					const double w = 1.0 / std::max(ex_ * ex_ + ez_ * ez_, 1.0e-12);
					const double dzv = (double)z[j] - (double)z[i];
					sxx += w * ex_ * ex_;
					sxz += w * ex_ * ez_;
					szz += w * ez_ * ez_;
					sx += w * ex_ * dzv;
					sz += w * ez_ * dzv;
				}
				const double det = sxx * szz - sxz * sxz;
				if (std::abs(det) > 1.0e-12 * std::max(sxx * szz, 1.0e-30)) {
					gx[i] = (szz * sx - sxz * sz) / det;
					gz[i] = (sxx * sz - sxz * sx) / det;
				}
			}
		}
		// Point location: a bucket grid of pitch ~ the point spacing, each triangle filed under every bucket
		// its bounding box touches.
		const int nt = (int)g.tris.size() / 3;
		const double bs = std::max(std::sqrt(rw * rh / std::max(nv, 1)) * 1.5, 1.0e-6);
		const int bw = std::max(1, (int)std::ceil(rw / bs));
		const int bh = std::max(1, (int)std::ceil(rh / bs));
		std::vector<int> b_start(bw * bh + 1, 0);
		auto bucket_range = [&](int t, int &bx0, int &bx1, int &bz0, int &bz1) {
			double mnx = 1e300, mxx = -1e300, mnz = 1e300, mxz = -1e300;
			for (int k = 0; k < 3; k++) {
				const int v = g.tris[t * 3 + k];
				mnx = std::min(mnx, g.px[v]);
				mxx = std::max(mxx, g.px[v]);
				mnz = std::min(mnz, g.pz[v]);
				mxz = std::max(mxz, g.pz[v]);
			}
			bx0 = std::clamp((int)std::floor((mnx - x0) / bs), 0, bw - 1);
			bx1 = std::clamp((int)std::floor((mxx - x0) / bs), 0, bw - 1);
			bz0 = std::clamp((int)std::floor((mnz - z0) / bs), 0, bh - 1);
			bz1 = std::clamp((int)std::floor((mxz - z0) / bs), 0, bh - 1);
		};
		for (int t = 0; t < nt; t++) {
			int a0, a1, c0, c1;
			bucket_range(t, a0, a1, c0, c1);
			for (int bz = c0; bz <= c1; bz++) {
				for (int bx = a0; bx <= a1; bx++) {
					b_start[bz * bw + bx + 1]++;
				}
			}
		}
		for (int i = 0; i < bw * bh; i++) {
			b_start[i + 1] += b_start[i];
		}
		std::vector<int> b_tris(b_start[bw * bh]);
		std::vector<int> b_fill(b_start.begin(), b_start.end() - 1);
		for (int t = 0; t < nt; t++) {
			int a0, a1, c0, c1;
			bucket_range(t, a0, a1, c0, c1);
			for (int bz = c0; bz <= c1; bz++) {
				for (int bx = a0; bx <= a1; bx++) {
					b_tris[b_fill[bz * bw + bx]++] = t;
				}
			}
		}

		// Warp: dx/dy (metres) plus, with `default_warp`, seeded fBm — faded to zero at the rect edge by a
		// biquadratic so no sample leaves the hull.
		const double w_amp = (p_params.warp_amount > 0.0f) ? (double)p_params.warp_amount : 0.02 * min_side;
		const double w_size = std::max((p_params.warp_size > 0.0f) ? (double)p_params.warp_size : 0.25 * min_side, 1.0e-6);
		const uint32_t wseed = (uint32_t)p_params.seed ^ 0x7f4a7c15u;

		Pasture3DThreadPool::parallel_for_rows(p_gh, 8, [&](int r0, int r1) {
			for (int iz = r0; iz < r1; iz++) {
				for (int ix = 0; ix < p_gw; ix++) {
					const int idx = iz * p_gw + ix;
					double qx = x0 + (ix + 0.5) * cell_dx;
					double qz = z0 + (iz + 0.5) * cell_dz;
					double wx = dx_ptr ? (double)dx_ptr[idx] : 0.0;
					double wz = dy_ptr ? (double)dy_ptr[idx] : 0.0;
					if (p_params.default_warp && !p_params.reconstruct_only) {
						wx += w_amp * saleve_fbm(qx / w_size, qz / w_size, wseed);
						wz += w_amp * saleve_fbm(qx / w_size, qz / w_size, wseed + 7919u);
					}
					if (wx != 0.0 || wz != 0.0) {
						const double u = (qx - x0) / rw, v = (qz - z0) / rh;
						const double fade = std::clamp(16.0 * u * (1.0 - u) * v * (1.0 - v), 0.0, 1.0);
						qx = std::clamp(qx + fade * wx, x0, x0 + rw);
						qz = std::clamp(qz + fade * wz, z0, z0 + rh);
					}
					const int bx = std::clamp((int)std::floor((qx - x0) / bs), 0, bw - 1);
					const int bz = std::clamp((int)std::floor((qz - z0) / bs), 0, bh - 1);
					const int bk = bz * bw + bx;
					int best_t = -1;
					double best_min = -1e300, bb[3] = { 0, 0, 0 };
					for (int q = b_start[bk]; q < b_start[bk + 1]; q++) {
						const int t = b_tris[q];
						const int a = g.tris[t * 3], b = g.tris[t * 3 + 1], c = g.tris[t * 3 + 2];
						const double d = (g.pz[b] - g.pz[c]) * (g.px[a] - g.px[c]) + (g.px[c] - g.px[b]) * (g.pz[a] - g.pz[c]);
						if (std::abs(d) < 1.0e-18) {
							continue;
						}
						const double l0 = ((g.pz[b] - g.pz[c]) * (qx - g.px[c]) + (g.px[c] - g.px[b]) * (qz - g.pz[c])) / d;
						const double l1 = ((g.pz[c] - g.pz[a]) * (qx - g.px[c]) + (g.px[a] - g.px[c]) * (qz - g.pz[c])) / d;
						const double l2 = 1.0 - l0 - l1;
						const double mn = std::min(l0, std::min(l1, l2));
						if (mn > best_min) {
							best_min = mn;
							best_t = t;
							bb[0] = l0;
							bb[1] = l1;
							bb[2] = l2;
							if (mn >= -1.0e-9) {
								break;
							}
						}
					}
					if (best_t < 0) {
						zg[idx] = 0.0f;
						continue;
					}
					if (best_min < 0.0) {
						// Just outside every triangle in the bucket (the hull edge): clamp onto the nearest one.
						double sum = 0.0;
						for (double &l : bb) {
							l = std::max(l, 0.0);
							sum += l;
						}
						for (double &l : bb) {
							l /= std::max(sum, 1.0e-12);
						}
					}
					const int vv[3] = { g.tris[best_t * 3], g.tris[best_t * 3 + 1], g.tris[best_t * 3 + 2] };
					double val = 0.0;
					if (p_params.reconstruction == 2) {
						int m = 0;
						for (int k = 1; k < 3; k++) {
							if (bb[k] > bb[m]) m = k;
						}
						val = z[vv[m]];
					} else if (p_params.reconstruction == 0) {
						val = bb[0] * z[vv[0]] + bb[1] * z[vv[1]] + bb[2] * z[vv[2]];
					} else {
						// Each vertex's tangent plane, blended by squared barycentrics: exact on a plane, and on
						// an edge only its two vertices take part, so neighbouring triangles agree.
						double ws = 0.0;
						for (int k = 0; k < 3; k++) {
							const int v = vv[k];
							const double w = bb[k] * bb[k];
							val += w * ((double)z[v] + gx[v] * (qx - g.px[v]) + gz[v] * (qz - g.pz[v]));
							ws += w;
						}
						val /= std::max(ws, 1.0e-30);
					}
					zg[idx] = (float)val;
				}
			}
		});
	}

	if (p_params.reconstruct_only) {
		res.ok = true;
		res.height.resize(n);
		res.eroded_rock.resize(n);
		res.eroded_rock.fill(0.0f);
		res.sediment.resize(n);
		res.sediment.fill(0.0f);
		for (int i = 0; i < n; i++) {
			res.height.set(i, std::isfinite(src_height[i]) ? zmin + zg[i] * zptp : src_height[i]);
		}
		return res;
	}

	// From here on the grid is in METRES: the Stage 1 field scaled by the reference relief, anchored at the
	// input's low point. Stage 3 (the stream-log solver) is metric, and so are the Stage 2 slopes.
	std::vector<float> hm(n);
	for (int i = 0; i < n; i++) {
		hm[i] = zmin + zg[i] * relief_ref;
	}
	const double rim = (p_params.rim_width > 0.0f) ? (double)p_params.rim_width : 0.1 * min_side;
	for (int i = 0; i < n; i++) {
		if (p_params.lower_only && std::isfinite(src_height[i]) && hm[i] > src_height[i]) {
			// Rim weight: 1 at the grid edge, smoothstep to 0 at `rim` metres in.
			float w = 1.0f;
			if (!p_params.cap_everywhere) {
				const int ix = i % p_gw;
				const int iz = i / p_gw;
				const double d = std::min(std::min((ix + 0.5) * cell_dx, (p_gw - 0.5 - ix) * cell_dx),
						std::min((iz + 0.5) * cell_dz, (p_gh - 0.5 - iz) * cell_dz));
				const double t = std::clamp(d / std::max(rim, 1.0e-6), 0.0, 1.0);
				w = (float)(1.0 - t * t * (3.0 - 2.0 * t));
			}
			hm[i] = hm[i] + w * (src_height[i] - hm[i]);
		}
	}

	// ================================================================================================
	// Stage 2: deposition. Fill every depression (priority flood from the border and from NaN cells), then
	// raise the fill to a blur of itself wherever it is concave: pits and valley floors become alluvial
	// flats, ridges are untouched. The blur reflects oddly at the edges, so it reproduces a plane exactly and
	// deposition is zero on one. target >= z always, so deposition only raises; it is weighted by flatness.
	// ================================================================================================
	std::vector<float> dep(n, 0.0f);
	if (p_params.deposition_strength > 0.0f) {
		std::vector<float> filled = hm;
		std::vector<uint8_t> done(n, 0);
		typedef std::pair<float, int> Entry;
		std::priority_queue<Entry, std::vector<Entry>, std::greater<Entry>> pq;
		for (int iz = 0; iz < p_gh; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = iz * p_gw + ix;
				if (!std::isfinite(src_height[i]) || ix == 0 || iz == 0 || ix == p_gw - 1 || iz == p_gh - 1) {
					done[i] = 1;
					pq.push(Entry(filled[i], i));
				}
			}
		}
		while (!pq.empty()) {
			const Entry e = pq.top();
			pq.pop();
			const int ix = e.second % p_gw, iz = e.second / p_gw;
			for (int dz = -1; dz <= 1; dz++) {
				for (int dxo = -1; dxo <= 1; dxo++) {
					const int nx = ix + dxo, nz = iz + dz;
					if ((dxo == 0 && dz == 0) || nx < 0 || nz < 0 || nx >= p_gw || nz >= p_gh) {
						continue;
					}
					const int j = nz * p_gw + nx;
					if (done[j]) {
						continue;
					}
					done[j] = 1;
					filled[j] = std::max(filled[j], e.first);
					pq.push(Entry(filled[j], j));
				}
			}
		}
		const double radius_m = p_params.deposition_radius > 0.0f ? (double)p_params.deposition_radius : 0.1 * min_side;
		const double cell_m = std::max(std::min(cell_dx, cell_dz), 1.0e-4);
		const int ir = std::clamp((int)std::lround(radius_m / cell_m), 1, std::max(1, std::min(p_gw, p_gh) / 2 - 1));
		// Separable box blur of the fill with odd reflection past the edges (a[-k] = 2 a[0] - a[k]).
		std::vector<float> tmp(n), blur(n);
		const float inv = 1.0f / (float)(2 * ir + 1);
		auto odd = [](const float *p_row, int p_stride, int p_len, int p_i) -> float {
			if (p_i < 0) {
				return 2.0f * p_row[0] - p_row[(-p_i) * p_stride];
			}
			if (p_i >= p_len) {
				return 2.0f * p_row[(p_len - 1) * p_stride] - p_row[(2 * (p_len - 1) - p_i) * p_stride];
			}
			return p_row[p_i * p_stride];
		};
		for (int iz = 0; iz < p_gh; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				float acc = 0.0f;
				for (int k = -ir; k <= ir; k++) {
					acc += odd(&filled[iz * p_gw], 1, p_gw, ix + k);
				}
				tmp[iz * p_gw + ix] = acc * inv;
			}
		}
		for (int iz = 0; iz < p_gh; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				float acc = 0.0f;
				for (int k = -ir; k <= ir; k++) {
					acc += odd(&tmp[ix], p_gw, p_gh, iz + k);
				}
				blur[iz * p_gw + ix] = acc * inv;
			}
		}
		for (int iz = 0; iz < p_gh; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = iz * p_gw + ix;
				if (!std::isfinite(src_height[i])) {
					continue;
				}
				const int xl = std::max(ix - 1, 0), xr = std::min(ix + 1, p_gw - 1);
				const int zl = std::max(iz - 1, 0), zr = std::min(iz + 1, p_gh - 1);
				// Flatness is read off the BLURRED surface, so it is near-uniform across a channel. Read off the
				// fill, a floor weighted 1 beside walls weighted 0 was raised above its own banks: a ridge down
				// the valley with a channel either side. With one weight across the section the fill keeps the
				// valley's order. `flat_from_fill` is the old reading, kept as the gate control.
				const std::vector<float> &fs = p_params.flat_from_fill ? filled : blur;
				const double gxs = (fs[iz * p_gw + xr] - fs[iz * p_gw + xl]) / (std::max(xr - xl, 1) * cell_dx);
				const double gzs = (fs[zr * p_gw + ix] - fs[zl * p_gw + ix]) / (std::max(zr - zl, 1) * cell_dz);
				const float flat = (float)std::clamp(1.0 - std::sqrt(gxs * gxs + gzs * gzs) / 0.5, 0.0, 1.0);
				const float target = std::max(filled[i], blur[i]);
				dep[i] = p_params.deposition_strength * flat * (target - hm[i]);
				hm[i] += dep[i];
			}
		}
	}

	// ================================================================================================
	// Stage 3: fine incision, the stream-log solver itself (not a copy of it) on the metric grid.
	// ================================================================================================
	if (p_params.debug_stages) {
		res.pre_stream.resize(n);
		std::memcpy(res.pre_stream.ptrw(), hm.data(), n * sizeof(float));
		res.deposition.resize(n);
		std::memcpy(res.deposition.ptrw(), dep.data(), n * sizeof(float));
	}
	if (p_params.stream_strength > 0.0f) {
		PackedFloat32Array surf;
		surf.resize(n);
		std::memcpy(surf.ptrw(), hm.data(), n * sizeof(float));
		HydraulicStreamLogParams sp;
		sp.incision_rate = p_params.stream_strength;
		sp.area_exponent = p_params.stream_exp;
		const HydraulicStreamLogResult sr = hydraulic_stream_log_solve(surf, p_gw, p_gh, p_rect, sp);
		if (sr.ok && sr.height.size() == n) {
			const float *h = sr.height.ptr();
			for (int i = 0; i < n; i++) {
				if (std::isfinite(h[i])) {
					hm[i] = h[i];
				}
			}
		}
	}
	if (p_params.debug_stages) {
		res.post_stream.resize(n);
		std::memcpy(res.post_stream.ptrw(), hm.data(), n * sizeof(float));
	}

	// ================================================================================================
	// Stage 4: Post-Processing
	// ================================================================================================
	if (p_params.enable_post_smoothing || p_params.bank_smoothing > 0.0f) {
		std::vector<float> smoothed = hm;
		float blend = p_params.enable_post_smoothing ? 0.3f : (p_params.bank_smoothing * 0.4f);
		Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int r0, int r1) {
			for (int iz = std::max(r0, 1); iz < std::min(r1, p_gh - 1); iz++) {
				for (int ix = 1; ix < p_gw - 1; ix++) {
					int idx = iz * p_gw + ix;
					float avg = 0.25f * (hm[iz * p_gw + ix - 1] + hm[iz * p_gw + ix + 1] +
							hm[(iz - 1) * p_gw + ix] + hm[(iz + 1) * p_gw + ix]);
					smoothed[idx] = (1.0f - blend) * hm[idx] + blend * avg;
				}
			}
		});
		hm = smoothed;
	}

	// Composite with the original heightfield. eroded_rock is the net lowering, sediment the Stage 2
	// raise, both under the same composite weight.
	res.height.resize(n);
	res.eroded_rock.resize(n);
	res.sediment.resize(n);
	float *h_out = res.height.ptrw();
	float *r_out = res.eroded_rock.ptrw();
	float *s_out = res.sediment.ptrw();
	Pasture3DThreadPool::parallel_for_elements(n, 4096, [&](int i0, int i1) {
		for (int i = i0; i < i1; i++) {
			const float orig_h = src_height[i];
			if (!std::isfinite(orig_h)) {
				h_out[i] = orig_h;
				r_out[i] = 0.0f;
				s_out[i] = 0.0f;
				continue;
			}
			const float m_val = has_mask ? mask_ptr[i] : 1.0f;
			const float w = p_params.erosion_strength * m_val;
			const float res_h = (1.0f - w) * orig_h + w * hm[i];
			h_out[i] = res_h;
			r_out[i] = std::max(0.0f, orig_h - res_h);
			s_out[i] = w * dep[i];
		}
	});
	res.ok = true;
	return res;
}
