// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Generate Range Splines. See pasture_3d_range_splines.h for the model.

#include "pasture_3d_range_splines.h"
#include "pasture_3d_geo_primitives.h"
#include "pasture_3d_path_query.h"
#include "pasture_3d_path_range.h"
#include "pasture_3d_thread_pool.h"

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>
#include <functional>
#include <limits>
#include <queue>
#include <vector>

using namespace godot;

RangeSplinesParams godot::range_splines_params_from(const float *p_params, int p_count) {
	RangeSplinesParams r;
	auto at = [&](int i, double d) -> double { return (p_params && i < p_count) ? (double)p_params[i] : d; };
	r.mode = std::clamp((int)std::lround(at(0, r.mode)), 0, 2);
	r.coast_inset = std::max(at(1, r.coast_inset), 0.0);
	r.seed = (int)std::lround(at(2, r.seed));
	r.peak_height = std::max(at(3, r.peak_height), 0.0);
	r.depth_scale = std::max(at(4, r.depth_scale), 1.0);
	r.height_from_depth = at(5, 1.0) >= 0.5;
	r.min_branch = std::max(at(6, r.min_branch), 0.0);
	r.count = std::clamp((int)std::lround(at(7, r.count)), 0, 500);
	r.angle = at(8, r.angle);
	r.spacing = std::max(at(9, r.spacing), 1.0);
	r.wander = std::max(at(10, r.wander), 0.0);
	r.length = std::max(at(11, r.length), 1.0);
	r.length_jitter = std::clamp(at(12, r.length_jitter), 0.0, 0.95);
	r.angle_jitter = std::clamp(at(13, r.angle_jitter), 0.0, 180.0);
	r.resolution = std::clamp((int)std::lround(at(14, r.resolution)), 32, 2048);
	r.step = std::max(at(15, r.step), 0.0);
	return r;
}

namespace {

constexpr double PI = 3.14159265358979323846;
// A cell is medial when its nearest outline point and a neighbour's are more than this many D apart along
// the outline. A rectangle's corner branches sit at exactly 2 D, so 3 removes them with margin; a main
// spine sits at 4 D or more even at its very ends.
constexpr double ARC_RATIO = 3.0;
constexpr int MAX_POINTS = 200000;
constexpr int SCATTER_TRIES = 60; // placement attempts per requested ridge

struct P2 {
	double x = 0.0, z = 0.0;
};
using Poly = std::vector<P2>;

double ss(double x) {
	const double t = std::clamp(x, 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

// A sequential seeded stream: consumed in a fixed order, so the same seed gives the same set.
struct Rng {
	uint32_t state;
	explicit Rng(uint32_t p_seed) : state(wang_hash(p_seed * 0x27D4EB2Du + 0x165667B1u)) {}
	double next() {
		state = wang_hash(state + 0x9E3779B9u);
		return (double)state / 4294967296.0;
	}
};

double poly_length(const Poly &p) {
	double l = 0.0;
	for (size_t i = 1; i < p.size(); i++) l += std::hypot(p[i].x - p[i - 1].x, p[i].z - p[i - 1].z);
	return l;
}

// Uniform arc-length resample, both ends kept.
Poly resample(const Poly &p, double p_step) {
	const double L = poly_length(p);
	if (p.size() < 2 || L <= 0.0) return p;
	const int n = std::max(1, (int)std::ceil(L / std::max(p_step, 1e-3)));
	Poly out;
	out.reserve((size_t)n + 1);
	size_t seg = 0;
	double seg_start = 0.0;
	double seg_len = std::hypot(p[1].x - p[0].x, p[1].z - p[0].z);
	for (int i = 0; i <= n; i++) {
		const double s = L * (double)i / (double)n;
		while (seg + 2 < p.size() && s > seg_start + seg_len) {
			seg_start += seg_len;
			seg++;
			seg_len = std::hypot(p[seg + 1].x - p[seg].x, p[seg + 1].z - p[seg].z);
		}
		const double f = seg_len > 0.0 ? std::clamp((s - seg_start) / seg_len, 0.0, 1.0) : 0.0;
		out.push_back({ p[seg].x + (p[seg + 1].x - p[seg].x) * f, p[seg].z + (p[seg + 1].z - p[seg].z) * f });
	}
	return out;
}

// Moving average over ±p_radius vertices, p_iters passes, ends pinned.
void smooth(Poly &p, int p_radius, int p_iters) {
	const int n = (int)p.size();
	if (n < 3 || p_radius <= 0) return;
	Poly tmp(p.size());
	for (int it = 0; it < p_iters; it++) {
		tmp[0] = p[0];
		tmp[(size_t)n - 1] = p[(size_t)n - 1];
		for (int i = 1; i < n - 1; i++) {
			const int r = std::min({ p_radius, i, n - 1 - i });
			double sx = 0.0, sz = 0.0;
			for (int k = -r; k <= r; k++) {
				sx += p[(size_t)(i + k)].x;
				sz += p[(size_t)(i + k)].z;
			}
			tmp[(size_t)i] = { sx / (2 * r + 1), sz / (2 * r + 1) };
		}
		p.swap(tmp);
	}
}

// The outline's inside distance: + inside (even-odd), - outside, metres.
double depth_at(const Pasture3DPathGeom &g, double x, double z, std::vector<int> &scratch, double *r_s = nullptr) {
	const Pasture3DPathHit h = g.nearest(x, z, scratch);
	if (h.segment < 0) return -std::numeric_limits<double>::infinity();
	if (r_s) *r_s = h.s;
	return g.inside(x, z) ? h.distance : -h.distance;
}

// Split `p` into runs with D >= inset, bisecting each crossing onto the inset line from the inside, and
// keep the runs at least `min_len` long.
void clip_to_inset(const Poly &p, const Pasture3DPathGeom &g, double inset, double min_len,
		std::vector<int> &scratch, std::vector<Poly> &r_out) {
	if (p.size() < 2) return;
	std::vector<double> d(p.size());
	for (size_t i = 0; i < p.size(); i++) d[i] = depth_at(g, p[i].x, p[i].z, scratch);
	auto crossing = [&](const P2 &in, const P2 &out) -> P2 {
		double lo = 0.0, hi = 1.0; // lo stays inside
		for (int it = 0; it < 24; it++) {
			const double m = 0.5 * (lo + hi);
			const double x = in.x + (out.x - in.x) * m, z = in.z + (out.z - in.z) * m;
			if (depth_at(g, x, z, scratch) >= inset) lo = m;
			else hi = m;
		}
		return { in.x + (out.x - in.x) * lo, in.z + (out.z - in.z) * lo };
	};
	Poly run;
	auto flush = [&]() {
		if (run.size() >= 2 && poly_length(run) >= min_len) r_out.push_back(run);
		run.clear();
	};
	for (size_t i = 0; i < p.size(); i++) {
		const bool in = d[i] >= inset;
		if (i > 0) {
			const bool was = d[i - 1] >= inset;
			if (was && !in) {
				run.push_back(crossing(p[i - 1], p[i]));
				flush();
			} else if (!was && in) {
				run.push_back(crossing(p[i], p[i - 1]));
			}
		}
		if (in) run.push_back(p[i]);
	}
	flush();
}

// ---- SPINE ------------------------------------------------------------------------------------------

struct Grid {
	int gw = 0, gh = 0;
	double ox = 0.0, oz = 0.0, cell = 1.0;
	int at(int ix, int iz) const { return iz * gw + ix; }
};

// Zhang-Suen thinning of a 0/1 mask whose one-cell border is 0.
void thin(std::vector<uint8_t> &m, const Grid &G) {
	std::vector<int> del;
	bool changed = true;
	while (changed) {
		changed = false;
		for (int pass = 0; pass < 2; pass++) {
			del.clear();
			for (int iz = 1; iz < G.gh - 1; iz++) {
				for (int ix = 1; ix < G.gw - 1; ix++) {
					if (!m[(size_t)G.at(ix, iz)]) continue;
					// P2..P9 clockwise from north.
					const int nb[8] = { m[(size_t)G.at(ix, iz - 1)], m[(size_t)G.at(ix + 1, iz - 1)], m[(size_t)G.at(ix + 1, iz)],
						m[(size_t)G.at(ix + 1, iz + 1)], m[(size_t)G.at(ix, iz + 1)], m[(size_t)G.at(ix - 1, iz + 1)],
						m[(size_t)G.at(ix - 1, iz)], m[(size_t)G.at(ix - 1, iz - 1)] };
					int b = 0, a = 0;
					for (int k = 0; k < 8; k++) {
						b += nb[k];
						if (!nb[k] && nb[(k + 1) % 8]) a++;
					}
					if (b < 2 || b > 6 || a != 1) continue;
					if (pass == 0) {
						if (nb[0] * nb[2] * nb[4] != 0 || nb[2] * nb[4] * nb[6] != 0) continue;
					} else {
						if (nb[0] * nb[2] * nb[6] != 0 || nb[0] * nb[4] * nb[6] != 0) continue;
					}
					del.push_back(G.at(ix, iz));
				}
			}
			for (int c : del) m[(size_t)c] = 0;
			if (!del.empty()) changed = true;
		}
	}
}

// Skeleton neighbours: the 8-neighbours that are set, minus any diagonal already reached through a set
// orthogonal neighbour (which would otherwise turn every staircase step into a fake junction).
int neighbours(const std::vector<uint8_t> &m, const Grid &G, int c, int r_out[8]) {
	const int ix = c % G.gw, iz = c / G.gw;
	int n = 0;
	auto on = [&](int x, int z) { return x >= 0 && z >= 0 && x < G.gw && z < G.gh && m[(size_t)G.at(x, z)] != 0; };
	static const int OX[4] = { 1, -1, 0, 0 }, OZ[4] = { 0, 0, 1, -1 };
	for (int k = 0; k < 4; k++) {
		if (on(ix + OX[k], iz + OZ[k])) r_out[n++] = G.at(ix + OX[k], iz + OZ[k]);
	}
	static const int DX[4] = { 1, 1, -1, -1 }, DZ[4] = { 1, -1, 1, -1 };
	for (int k = 0; k < 4; k++) {
		const int x = ix + DX[k], z = iz + DZ[k];
		if (on(x, z) && !on(ix + DX[k], iz) && !on(ix, iz + DZ[k])) r_out[n++] = G.at(x, z);
	}
	return n;
}

// Remove leaf branches shorter than `p_min` metres, the shortest per junction per round, until none.
void prune(std::vector<uint8_t> &m, const Grid &G, double p_min) {
	const int N = G.gw * G.gh;
	std::vector<int> deg((size_t)N, 0);
	while (true) {
		for (int c = 0; c < N; c++) {
			int nb[8];
			deg[(size_t)c] = m[(size_t)c] ? neighbours(m, G, c, nb) : 0;
		}
		std::vector<std::vector<int>> removals;
		// junction cell -> (length, chain) of its shortest short leaf
		std::vector<int> jcell;
		std::vector<double> jlen;
		std::vector<std::vector<int>> jchain;
		bool any = false;
		for (int c = 0; c < N; c++) {
			if (!m[(size_t)c]) continue;
			if (deg[(size_t)c] == 0) {
				m[(size_t)c] = 0; // an isolated cell is no spine
				any = true;
				continue;
			}
			if (deg[(size_t)c] != 1) continue;
			// Walk from this leaf to the next non-degree-2 cell.
			std::vector<int> chain{ c };
			double len = 0.0;
			int prev = -1, cur = c;
			while (true) {
				int nb[8];
				const int k = neighbours(m, G, cur, nb);
				int next = -1;
				for (int j = 0; j < k; j++) {
					if (nb[j] != prev) {
						next = nb[j];
						break;
					}
				}
				if (next < 0) break;
				const int dxi = std::abs(next % G.gw - cur % G.gw), dzi = std::abs(next / G.gw - cur / G.gw);
				len += (dxi + dzi == 2 ? std::sqrt(2.0) : 1.0) * G.cell;
				prev = cur;
				cur = next;
				if (deg[(size_t)cur] != 2) break;
				chain.push_back(cur);
			}
			if (len >= p_min) continue;
			if (deg[(size_t)cur] == 1) {
				// An isolated short chain: both ends are leaves. Remove all of it, junction-free.
				if (cur > c) { // once, from its lower end
					chain.push_back(cur);
					removals.push_back(chain);
				}
				continue;
			}
			// A short leaf off junction `cur`: keep only the shortest per junction.
			bool found = false;
			for (size_t j = 0; j < jcell.size(); j++) {
				if (jcell[j] == cur) {
					found = true;
					if (len < jlen[j]) {
						jlen[j] = len;
						jchain[j] = chain;
					}
				}
			}
			if (!found) {
				jcell.push_back(cur);
				jlen.push_back(len);
				jchain.push_back(chain);
			}
		}
		for (auto &ch : jchain) removals.push_back(ch);
		for (auto &ch : removals) {
			for (int c : ch) m[(size_t)c] = 0;
			any = true;
		}
		if (!any) break;
	}
}

// Cut the skeleton into polylines, longest chain first (double-sweep Dijkstra per component), each later
// chain extended by one cell onto a chain already taken so branches meet the line they leave.
void extract(std::vector<uint8_t> &m, const Grid &G, double p_min, std::vector<Poly> &r_out) {
	const int N = G.gw * G.gh;
	std::vector<uint8_t> used((size_t)N, 0);
	std::vector<double> dist((size_t)N);
	std::vector<int> pred((size_t)N);
	auto cell_w = [&](int c) -> P2 { return { G.ox + (c % G.gw + 0.5) * G.cell, G.oz + (c / G.gw + 0.5) * G.cell }; };
	auto sweep = [&](int src, std::vector<int> &r_touched) -> int {
		using QE = std::pair<double, int>;
		std::priority_queue<QE, std::vector<QE>, std::greater<QE>> q;
		dist[(size_t)src] = 0.0;
		pred[(size_t)src] = -1;
		r_touched.push_back(src);
		q.push({ 0.0, src });
		int far = src;
		while (!q.empty()) {
			const auto [d, c] = q.top();
			q.pop();
			if (d > dist[(size_t)c]) continue;
			if (d > dist[(size_t)far] || (d == dist[(size_t)far] && c < far)) far = c;
			int nb[8];
			const int k = neighbours(m, G, c, nb);
			for (int j = 0; j < k; j++) {
				const int n = nb[j];
				const int dxi = std::abs(n % G.gw - c % G.gw), dzi = std::abs(n / G.gw - c / G.gw);
				const double nd = d + (dxi + dzi == 2 ? std::sqrt(2.0) : 1.0) * G.cell;
				if (nd < dist[(size_t)n]) {
					if (dist[(size_t)n] == std::numeric_limits<double>::infinity()) r_touched.push_back(n);
					dist[(size_t)n] = nd;
					pred[(size_t)n] = c;
					q.push({ nd, n });
				}
			}
		}
		return far;
	};
	std::fill(dist.begin(), dist.end(), std::numeric_limits<double>::infinity());
	std::vector<int> touched;
	auto reset = [&]() {
		for (int c : touched) dist[(size_t)c] = std::numeric_limits<double>::infinity();
		touched.clear();
	};
	auto attach = [&](int c, Poly &p, bool front) {
		const int ix = c % G.gw, iz = c / G.gw;
		for (int dz = -1; dz <= 1; dz++) {
			for (int dx = -1; dx <= 1; dx++) {
				const int x = ix + dx, z = iz + dz;
				if ((dx || dz) && x >= 0 && z >= 0 && x < G.gw && z < G.gh && used[(size_t)G.at(x, z)]) {
					const P2 w = cell_w(G.at(x, z));
					if (front) p.insert(p.begin(), w);
					else p.push_back(w);
					return;
				}
			}
		}
	};
	while (true) {
		// The longest chain over every remaining component, so the order is global and deterministic.
		double best_len = -1.0;
		std::vector<int> best_path;
		std::vector<uint8_t> seen((size_t)N, 0);
		for (int c = 0; c < N; c++) {
			if (!m[(size_t)c] || seen[(size_t)c]) continue;
			reset();
			const int a = sweep(c, touched);
			for (int t : touched) seen[(size_t)t] = 1;
			reset();
			const int b = sweep(a, touched);
			const double len = dist[(size_t)b];
			if (len > best_len) {
				best_len = len;
				best_path.clear();
				for (int v = b; v >= 0; v = pred[(size_t)v]) best_path.push_back(v);
			}
		}
		reset();
		if (best_len < 0.0 || best_len < p_min || best_path.size() < 2) break;
		Poly p;
		for (int c : best_path) p.push_back(cell_w(c));
		attach(best_path.front(), p, true);
		attach(best_path.back(), p, false);
		for (int c : best_path) {
			m[(size_t)c] = 0;
			used[(size_t)c] = 1;
		}
		r_out.push_back(std::move(p));
		if (r_out.size() > 4096) break;
	}
}

void spine(const Pasture3DPathGeom &g, double bx0, double bz0, double bx1, double bz1, const RangeSplinesParams &P,
		double p_step, std::vector<Poly> &r_out) {
	Grid G;
	const double ext = std::max(bx1 - bx0, bz1 - bz0);
	G.cell = ext / (double)P.resolution;
	G.ox = bx0 - 2.0 * G.cell;
	G.oz = bz0 - 2.0 * G.cell;
	G.gw = (int)std::ceil((bx1 - bx0) / G.cell) + 4;
	G.gh = (int)std::ceil((bz1 - bz0) / G.cell) + 4;
	const int N = G.gw * G.gh;
	std::vector<double> D((size_t)N), S((size_t)N);
	Pasture3DThreadPool::parallel_for_rows(G.gh, 8, [&](int r0, int r1) {
		std::vector<int> scratch;
		for (int iz = r0; iz < r1; iz++) {
			for (int ix = 0; ix < G.gw; ix++) {
				double s = 0.0;
				const double d = depth_at(g, G.ox + (ix + 0.5) * G.cell, G.oz + (iz + 0.5) * G.cell, scratch, &s);
				D[(size_t)G.at(ix, iz)] = d;
				S[(size_t)G.at(ix, iz)] = s;
			}
		}
	});
	const double L = g.length();
	std::vector<uint8_t> m((size_t)N, 0);
	auto test = [&](int a, int b) {
		if (!(D[(size_t)a] > 0.0) || !(D[(size_t)b] > 0.0)) return;
		double ds = std::abs(S[(size_t)a] - S[(size_t)b]);
		ds = std::min(ds, L - ds);
		if (ds > ARC_RATIO * std::max(D[(size_t)a], D[(size_t)b])) {
			m[(size_t)a] = 1;
			m[(size_t)b] = 1;
		}
	};
	for (int iz = 1; iz < G.gh - 1; iz++) {
		for (int ix = 1; ix < G.gw - 1; ix++) {
			const int c = G.at(ix, iz);
			if (ix + 1 < G.gw - 1) test(c, G.at(ix + 1, iz));
			if (iz + 1 < G.gh - 1) test(c, G.at(ix, iz + 1));
		}
	}
	thin(m, G);
	prune(m, G, P.min_branch);
	std::vector<Poly> raw;
	extract(m, G, P.min_branch, raw);
	for (Poly &p : raw) {
		smooth(p, 2, 4);
		r_out.push_back(resample(p, p_step));
	}
}

// ---- FOLDS and SCATTER ------------------------------------------------------------------------------

void folds(double cx, double cz, double p_reach, const RangeSplinesParams &P, double p_step, uint32_t p_salt,
		std::vector<Poly> &r_out) {
	const double a = P.angle * PI / 180.0;
	const double ux = std::sin(a), uz = -std::cos(a); // along the crest
	const double vx = std::cos(a), vz = std::sin(a); // across it
	const int n = std::max(1, (int)std::ceil(2.0 * p_reach / p_step));
	for (int k = 0; k < P.count; k++) {
		const double o = ((double)k - 0.5 * (double)(P.count - 1)) * P.spacing;
		const uint32_t salt = wang_hash(p_salt + 0x9E3779B9u * (uint32_t)(k + 1));
		Poly p;
		p.reserve((size_t)n + 1);
		for (int i = 0; i <= n; i++) {
			const double t = -p_reach + 2.0 * p_reach * (double)i / (double)n;
			const double off = o + (P.wander > 0.0 ? P.wander * path_range_noise1(t / (4.0 * P.spacing), salt) : 0.0);
			p.push_back({ cx + ux * t + vx * off, cz + uz * t + vz * off });
		}
		r_out.push_back(std::move(p));
	}
}

void scatter(const Pasture3DPathGeom &g, double bx0, double bz0, double bx1, double bz1, const RangeSplinesParams &P,
		double p_step, std::vector<Poly> &r_out) {
	Rng rng((uint32_t)P.seed);
	std::vector<int> scratch;
	const int tries = P.count * SCATTER_TRIES;
	for (int t = 0; t < tries && (int)r_out.size() < P.count; t++) {
		// Fixed draw order per attempt, whatever the attempt's fate: x, z, length, angle, bend seed.
		const double x = bx0 + (bx1 - bx0) * rng.next();
		const double z = bz0 + (bz1 - bz0) * rng.next();
		const double len = P.length * (1.0 + P.length_jitter * (2.0 * rng.next() - 1.0));
		const double ang = (P.angle + P.angle_jitter * (2.0 * rng.next() - 1.0)) * PI / 180.0;
		const uint32_t bend = (uint32_t)(rng.next() * 4294967295.0);
		if (depth_at(g, x, z, scratch) < P.coast_inset) continue;
		const double ux = std::sin(ang), uz = -std::cos(ang);
		const int m = std::max(4, (int)std::ceil(len / p_step));
		Poly p;
		p.reserve((size_t)m + 1);
		for (int j = 0; j <= m; j++) {
			const double u = (double)j / (double)m;
			const double off = P.wander > 0.0 ? P.wander * path_range_noise1(u * 2.0, bend) * std::sin(PI * u) : 0.0;
			const double along = (u - 0.5) * len;
			p.push_back({ x + ux * along - uz * off, z + uz * along + ux * off });
		}
		bool near = false;
		const double sp2 = P.spacing * P.spacing;
		for (const Poly &q : r_out) {
			for (const P2 &a : p) {
				for (const P2 &b : q) {
					const double dx = a.x - b.x, dz = a.z - b.z;
					if (dx * dx + dz * dz < sp2) {
						near = true;
						break;
					}
				}
				if (near) break;
			}
			if (near) break;
		}
		if (!near) r_out.push_back(std::move(p));
	}
}

} // namespace

Dictionary godot::range_splines_solve(const PackedVector2Array &p_outline, bool p_closed, const RangeSplinesParams &P) {
	Dictionary out;
	PackedVector2Array pts;
	PackedFloat32Array hts;
	PackedInt32Array starts;
	out["points"] = pts;
	out["heights"] = hts;
	out["part_starts"] = starts;
	if (!p_closed || p_outline.size() < 3) return out;

	Pasture3DPathGeom g;
	path_geom_build(g, p_outline, true, PackedFloat32Array());
	if (g.is_empty() || !(g.length() > 0.0)) return out;
	double bx0 = 1e300, bz0 = 1e300, bx1 = -1e300, bz1 = -1e300;
	for (int i = 0; i < p_outline.size(); i++) {
		bx0 = std::min(bx0, (double)p_outline[i].x);
		bx1 = std::max(bx1, (double)p_outline[i].x);
		bz0 = std::min(bz0, (double)p_outline[i].y);
		bz1 = std::max(bz1, (double)p_outline[i].y);
	}
	const double ext = std::max(bx1 - bx0, bz1 - bz0);
	if (!(ext > 0.0)) return out;
	const double step = P.step > 0.0 ? P.step : ext / 256.0;
	const uint32_t salt = wang_hash((uint32_t)P.seed * 0x85EBCA6Bu + 0x7F4A7C15u);

	std::vector<Poly> lines;
	switch (P.mode) {
		case RANGE_SPLINES_FOLDS:
			folds(0.5 * (bx0 + bx1), 0.5 * (bz0 + bz1), 0.5 * std::hypot(bx1 - bx0, bz1 - bz0), P, step, salt, lines);
			break;
		case RANGE_SPLINES_SCATTER:
			scatter(g, bx0, bz0, bx1, bz1, P, step, lines);
			break;
		case RANGE_SPLINES_SPINE:
		default:
			spine(g, bx0, bz0, bx1, bz1, P, step, lines);
			break;
	}

	std::vector<int> scratch;
	std::vector<Poly> parts;
	for (const Poly &l : lines) clip_to_inset(l, g, P.coast_inset, P.min_branch, scratch, parts);

	for (const Poly &p : parts) {
		if (pts.size() + (int)p.size() > MAX_POINTS) break;
		if (pts.size() > 0) starts.push_back(pts.size());
		for (const P2 &v : p) {
			pts.push_back(Vector2((real_t)v.x, (real_t)v.z));
			double h = P.peak_height;
			if (P.height_from_depth) h *= ss(std::max(depth_at(g, v.x, v.z, scratch), 0.0) / P.depth_scale);
			hts.push_back((float)h);
		}
	}
	out["points"] = pts;
	out["heights"] = hts;
	out["part_starts"] = starts;
	return out;
}
