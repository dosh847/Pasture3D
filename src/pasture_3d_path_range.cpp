// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Path Range kernel. The model is in pasture_3d_path_range.h. Distances are the shared Pasture3DPathGeom
// query, noise is the shared wang_hash (1D, along arc length) and fractal_grid (2D detail); threading is
// Pasture3DThreadPool.

#include "pasture_3d_path_range.h"
#include "pasture_3d_fractal.h"
#include "pasture_3d_geo_primitives.h"
#include "pasture_3d_path_query.h"
#include "pasture_3d_thread_pool.h"

#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>
#include <memory>
#include <vector>

using namespace godot;

PathRangeParams godot::path_range_params_from(const float *p_params, int p_count) {
	PathRangeParams r;
	auto at = [&](int i, double d) -> double { return (p_params && i < p_count) ? (double)p_params[i] : d; };
	r.peak_height = std::max(at(0, r.peak_height), 0.0);
	r.peak_spacing = std::max(at(1, r.peak_spacing), 1.0);
	r.peak_variation = std::clamp(at(2, r.peak_variation), 0.0, 2.0);
	r.end_taper = std::max(at(3, r.end_taper), 0.0);
	r.end_height = std::clamp(at(4, r.end_height), 0.0, 1.0);
	r.width_ratio = std::max(at(5, r.width_ratio), 0.05);
	r.spur_spacing = std::max(at(6, r.spur_spacing), 1.0);
	r.spur_length = std::max(at(7, r.spur_length), 0.0);
	r.spur_angle = std::clamp(at(8, r.spur_angle), -80.0, 80.0);
	r.spur_angle_jitter = std::clamp(at(9, r.spur_angle_jitter), 0.0, 80.0);
	r.spur_wander = std::clamp(at(10, r.spur_wander), 0.0, 2.0);
	r.spur_levels = std::clamp((int)std::lround(at(11, r.spur_levels)), 0, 2);
	r.blend_k = std::max(at(12, r.blend_k), 0.0);
	r.detail = std::clamp(at(13, r.detail), 0.0, 1.0);
	r.seed = (int)std::lround(at(14, r.seed));
	const int flags = std::max((int)std::lround(at(15, 0.0)), 0);
	r.crest_shape = std::clamp(flags & 3, 0, 2);
	r.max_blend = (flags & 4) != 0;
	r.use_path_heights = (flags & 8) != 0;
	return r;
}

namespace {

constexpr double SPUR_ROOT = 0.85; // a spur leaves the crest at this fraction of the crest height
constexpr double MIN_HALF_WIDTH = 10.0; // metres; a ridge never narrows below this
constexpr int MAX_CREST_SAMPLES = 20000;
constexpr int MAX_SPUR_SAMPLES = 200;
constexpr double PI = 3.14159265358979323846;

double ss(double x) {
	const double t = std::clamp(x, 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

// Uniform [0, 1) from an integer lattice index and a salt, by the shared hash.
double hash01(int64_t p_i, uint32_t p_salt) {
	const uint32_t a = wang_hash((uint32_t)(p_i & 0xffffffff) * 0x9E3779B1u ^ p_salt);
	return (double)a / 4294967296.0;
}

// 1D value-noise fBm in [-1, 1], four octaves. u is in wavelengths.
double n1(double p_u, uint32_t p_salt) {
	double sum = 0.0, amp = 1.0, norm = 0.0, f = 1.0;
	for (int o = 0; o < 4; o++) {
		const double x = p_u * f;
		const double fl = std::floor(x);
		const int64_t i = (int64_t)fl;
		const double t = ss(x - fl);
		const uint32_t salt = wang_hash(p_salt + 0x632BE5ABu * (uint32_t)(o + 1));
		const double a = hash01(i, salt) * 2.0 - 1.0;
		const double b = hash01(i + 1, salt) * 2.0 - 1.0;
		sum += amp * (a + (b - a) * t);
		norm += amp;
		amp *= 0.5;
		f *= 2.0;
	}
	return sum / norm;
}

double xsec(int p_shape, double p_x) {
	if (p_x >= 1.0) return 0.0;
	const double x = std::max(p_x, 0.0);
	switch (p_shape) {
		case PATH_RANGE_SHARP:
			return (1.0 - x) * (1.0 - x);
		case PATH_RANGE_FLAT:
			return x <= 0.4 ? 1.0 : 1.0 - ss((x - 0.4) / 0.6);
		case PATH_RANGE_ROUND:
		default:
			return 0.5 + 0.5 * std::cos(PI * x);
	}
}

// A smooth max whose radius shrinks with the smaller value, so a line fading to 0 adds nothing.
double smax(double p_a, double p_b, double p_k) {
	const double m = std::max(p_a, p_b);
	const double kk = std::min(p_k, std::min(p_a, p_b));
	if (kk <= 0.0) return m;
	const double h = std::max(kk - std::abs(p_a - p_b), 0.0) / kk;
	return m + kk * h * h * 0.25;
}

struct Line {
	std::vector<float> x, z, h;
};

// Build a line's geometry: widths from heights, heights carried for height_at.
std::unique_ptr<Pasture3DPathGeom> build_geom(const Line &p_l, double p_ratio) {
	auto g = std::make_unique<Pasture3DPathGeom>();
	const int m = (int)p_l.x.size();
	PackedVector2Array pts;
	PackedFloat32Array w, hh;
	pts.resize(m);
	w.resize(m);
	hh.resize(m);
	for (int i = 0; i < m; i++) {
		pts.set(i, Vector2(p_l.x[i], p_l.z[i]));
		w.set(i, (float)std::max(p_ratio * (double)p_l.h[i], MIN_HALF_WIDTH));
		hh.set(i, p_l.h[i]);
	}
	if (!g->build(pts, w, hh)) return nullptr;
	return g;
}

// Spurs off a parent line. `p_ref` is the height that gives a full-length spur.
void grow_spurs(const Pasture3DPathGeom &p_parent, double p_spacing, double p_length, double p_ref,
		double p_step, const PathRangeParams &P, uint32_t p_salt, std::vector<Line> &r_out) {
	const double L = p_parent.length();
	if (L <= 0.0 || p_length <= 0.0) return;
	const int count = (int)std::floor(L / p_spacing);
	const int first = hash01(0, p_salt ^ 0x51ED27u) < 0.5 ? 1 : -1;
	const double d2r = PI / 180.0;
	for (int k = 0; k < count; k++) {
		const uint32_t sk = wang_hash(p_salt + 0x9E3779B9u * (uint32_t)(k + 1));
		const double s = p_spacing * (k + 0.5 + (hash01(k, sk ^ 1u) - 0.5) * 0.5);
		if (s <= 0.0 || s >= L) continue;
		const double hp = p_parent.height_at(s);
		if (!std::isfinite(hp) || hp <= 0.0) continue;
		const double len = p_length * (0.6 + 0.8 * hash01(k, sk ^ 2u)) * std::min(hp / std::max(p_ref, 1e-3), 2.0);
		if (len < 1.0) continue;
		const double ds = std::min(p_step, 0.25 * L);
		const double s0 = std::max(s - ds, 0.0), s1 = std::min(s + ds, L);
		double tx = p_parent.lerp_vertex(p_parent.px, s1) - p_parent.lerp_vertex(p_parent.px, s0);
		double tz = p_parent.lerp_vertex(p_parent.pz, s1) - p_parent.lerp_vertex(p_parent.pz, s0);
		const double tl = std::sqrt(tx * tx + tz * tz);
		if (tl < 1e-9) continue;
		tx /= tl;
		tz /= tl;
		const double side = (k % 2 == 0) ? first : -first;
		const double a = (P.spur_angle + P.spur_angle_jitter * (2.0 * hash01(k, sk ^ 3u) - 1.0)) * d2r;
		// Normal on `side`, raked back toward the parent's start.
		double dx = -tz * side * std::cos(a) - tx * std::sin(a);
		double dz = tx * side * std::cos(a) - tz * std::sin(a);
		const double dl = std::sqrt(dx * dx + dz * dz);
		dx /= dl;
		dz /= dl;
		const double rx = p_parent.lerp_vertex(p_parent.px, s), rz = p_parent.lerp_vertex(p_parent.pz, s);
		const int m = std::clamp((int)std::ceil(len / std::max(p_step, 1.0)), 4, MAX_SPUR_SAMPLES);
		Line l;
		l.x.resize(m + 1);
		l.z.resize(m + 1);
		l.h.resize(m + 1);
		for (int j = 0; j <= m; j++) {
			const double u = (double)j / (double)m;
			const double off = P.spur_wander * len * n1(u * 2.0, sk ^ 4u) * std::sin(PI * u);
			l.x[j] = (float)(rx + dx * u * len - dz * off);
			l.z[j] = (float)(rz + dz * u * len + dx * off);
			l.h[j] = (float)(SPUR_ROOT * hp * 0.5 * (1.0 + std::cos(PI * u)));
		}
		r_out.push_back(std::move(l));
	}
}

} // namespace

Dictionary godot::path_range_grid_geom(const Pasture3DPathGeom *p_crest, const PackedFloat32Array &p_base,
		const PackedFloat32Array &p_amount, int p_gw, int p_gh, const Rect2 &p_rect, const PathRangeParams &p_prm) {
	Dictionary out;
	const int n = p_gw * p_gh;
	if (p_gw <= 0 || p_gh <= 0) return out;
	const PathRangeParams P = p_prm;
	const float *base = p_base.size() == n ? p_base.ptr() : nullptr;
	const float *amt = p_amount.size() == n ? p_amount.ptr() : nullptr;

	std::vector<double> field((size_t)n, 0.0), env((size_t)n, 0.0), crest((size_t)n, 0.0), foot((size_t)n, 0.0);

	if (p_crest && !p_crest->is_empty() && p_crest->length() > 0.0) {
		const Pasture3DPathGeom &C = *p_crest;
		const double L = C.length();
		const uint32_t salt = wang_hash((uint32_t)P.seed * 0x85EBCA6Bu + 0x1234567u);
		// 1. The crest, resampled in world metres so the result does not move with the grid.
		double step = std::max(std::min({ P.peak_spacing, P.spur_spacing, L }) / 8.0, 1.0);
		int ns = (int)std::ceil(L / step);
		if (ns > MAX_CREST_SAMPLES) {
			ns = MAX_CREST_SAMPLES;
			step = L / ns;
		}
		const bool heights = P.use_path_heights && !C.height.empty();
		Line cl;
		cl.x.resize(ns + 1);
		cl.z.resize(ns + 1);
		cl.h.resize(ns + 1);
		for (int i = 0; i <= ns; i++) {
			const double s = L * (double)i / (double)ns;
			double b = P.peak_height;
			if (heights) {
				const double hp = C.height_at(s);
				if (std::isfinite(hp)) b = hp;
			}
			const double var = std::max(0.0, 1.0 + P.peak_variation * n1(s / P.peak_spacing, salt));
			double taper = 1.0;
			if (!C.closed && P.end_taper > 0.0) {
				taper = P.end_height + (1.0 - P.end_height) * ss(std::min(s, L - s) / P.end_taper);
			}
			cl.x[i] = (float)C.lerp_vertex(C.px, s);
			cl.z[i] = (float)C.lerp_vertex(C.pz, s);
			cl.h[i] = (float)std::max(b * taper * var, 0.0);
		}
		// 2. Lines: the crest, its spurs, and their spurs.
		std::vector<Line> lines;
		lines.push_back(cl);
		std::vector<std::unique_ptr<Pasture3DPathGeom>> geoms;
		geoms.push_back(build_geom(lines[0], P.width_ratio));
		if (P.spur_levels >= 1 && geoms[0]) {
			std::vector<Line> l1;
			grow_spurs(*geoms[0], P.spur_spacing, P.spur_length, P.peak_height, step, P, salt ^ 0xA5A5A5u, l1);
			for (auto &l : l1) {
				lines.push_back(std::move(l));
				geoms.push_back(build_geom(lines.back(), P.width_ratio));
			}
			if (P.spur_levels >= 2) {
				const size_t first_l1 = 1, end_l1 = geoms.size();
				for (size_t li = first_l1; li < end_l1; li++) {
					if (!geoms[li]) continue;
					std::vector<Line> l2;
					grow_spurs(*geoms[li], 0.5 * P.spur_spacing, 0.5 * P.spur_length, P.peak_height, 0.5 * step, P,
							wang_hash(salt ^ (uint32_t)(li * 7919u)), l2);
					for (auto &l : l2) {
						lines.push_back(std::move(l));
						geoms.push_back(build_geom(lines.back(), P.width_ratio));
					}
				}
			}
		}
		// 3. Rasterise each line over its own box, in line order (deterministic).
		const double dx = (double)p_rect.size.x / (double)p_gw;
		const double dz = (double)p_rect.size.y / (double)p_gh;
		for (size_t li = 0; li < geoms.size(); li++) {
			const Pasture3DPathGeom *g = geoms[li].get();
			if (!g) continue;
			const Line &l = lines[li];
			double x0 = 1e30, x1 = -1e30, z0 = 1e30, z1 = -1e30, reach = MIN_HALF_WIDTH;
			for (size_t j = 0; j < l.x.size(); j++) {
				x0 = std::min(x0, (double)l.x[j]);
				x1 = std::max(x1, (double)l.x[j]);
				z0 = std::min(z0, (double)l.z[j]);
				z1 = std::max(z1, (double)l.z[j]);
				reach = std::max(reach, P.width_ratio * (double)l.h[j]);
			}
			const int ix0 = std::max(0, (int)std::floor((x0 - reach - p_rect.position.x) / dx - 0.5));
			const int ix1 = std::min(p_gw - 1, (int)std::ceil((x1 + reach - p_rect.position.x) / dx - 0.5));
			const int iz0 = std::max(0, (int)std::floor((z0 - reach - p_rect.position.y) / dz - 0.5));
			const int iz1 = std::min(p_gh - 1, (int)std::ceil((z1 + reach - p_rect.position.y) / dz - 0.5));
			if (ix0 > ix1 || iz0 > iz1) continue;
			// A line's value at a cell is the MAX over its segments of h(t) · xsec(d / hw(t)), each segment
			// measured to its own clamped projection. Not the single nearest point: a line's height varies
			// along it, and on the inside of a bend the nearest point jumps from one stretch to another across
			// the medial axis, which steps the height by the difference (a 58 m cliff on a wandering spur).
			// Each segment's term is continuous and so is their max. Within one line it is a hard max, as
			// a line is one ridge; blend_k merges between lines.
			const int segs = g->segment_count();
			std::vector<double> sz0((size_t)segs), sz1((size_t)segs), sx0((size_t)segs), sx1((size_t)segs);
			for (int k = 0; k < segs; k++) {
				const double r = std::max((double)g->width[(size_t)k], (double)g->width[(size_t)k + 1]);
				sz0[(size_t)k] = std::min(g->pz[(size_t)k], g->pz[(size_t)k + 1]) - r;
				sz1[(size_t)k] = std::max(g->pz[(size_t)k], g->pz[(size_t)k + 1]) + r;
				sx0[(size_t)k] = std::min(g->px[(size_t)k], g->px[(size_t)k + 1]) - r;
				sx1[(size_t)k] = std::max(g->px[(size_t)k], g->px[(size_t)k + 1]) + r;
			}
			Pasture3DThreadPool::parallel_for_rows(iz1 - iz0 + 1, 8, [&](int r0, int r1) {
				const int bwid = ix1 - ix0 + 1;
				std::vector<double> lv((size_t)bwid), lx((size_t)bwid), lh((size_t)bwid);
				for (int iz = iz0 + r0; iz < iz0 + r1; iz++) {
					const double wz = p_rect.position.y + (iz + 0.5) * dz;
					std::fill(lv.begin(), lv.end(), 0.0);
					std::fill(lx.begin(), lx.end(), 1.0);
					std::fill(lh.begin(), lh.end(), 0.0);
					for (int k = 0; k < segs; k++) {
						if (wz < sz0[(size_t)k] || wz > sz1[(size_t)k]) continue;
						const double ax = g->px[(size_t)k], az = g->pz[(size_t)k];
						const double ex = g->px[(size_t)k + 1] - ax, ez = g->pz[(size_t)k + 1] - az;
						const double ee = ex * ex + ez * ez;
						const double ha = g->height[(size_t)k], hb = g->height[(size_t)k + 1];
						const double wa = g->width[(size_t)k], wb = g->width[(size_t)k + 1];
						const int c0 = std::max(ix0, (int)std::floor((sx0[(size_t)k] - p_rect.position.x) / dx - 0.5));
						const int c1 = std::min(ix1, (int)std::ceil((sx1[(size_t)k] - p_rect.position.x) / dx - 0.5));
						for (int ix = c0; ix <= c1; ix++) {
							const double wx = p_rect.position.x + (ix + 0.5) * dx;
							const double t = ee > 0.0 ? std::clamp(((wx - ax) * ex + (wz - az) * ez) / ee, 0.0, 1.0) : 0.0;
							const double hl = ha + (hb - ha) * t;
							if (!(hl > 0.0)) continue;
							const double qx = wx - (ax + ex * t), qz = wz - (az + ez * t);
							const double x = std::sqrt(qx * qx + qz * qz) / std::max(wa + (wb - wa) * t, 1e-6);
							if (x >= 1.0) continue;
							const size_t j = (size_t)(ix - ix0);
							lv[j] = std::max(lv[j], hl * xsec(P.crest_shape, x));
							lx[j] = std::min(lx[j], x);
							lh[j] = std::max(lh[j], hl);
						}
					}
					for (int ix = ix0; ix <= ix1; ix++) {
						const size_t j = (size_t)(ix - ix0);
						if (lx[j] >= 1.0) continue;
						const size_t i = (size_t)iz * p_gw + ix;
						field[i] = smax(field[i], lv[j], P.blend_k);
						env[i] = std::max(env[i], lh[j]);
						crest[i] = std::max(crest[i], 1.0 - lx[j]);
						foot[i] = std::max(foot[i], ss((1.0 - lx[j]) / 0.2));
					}
				}
			});
		}
		// 4. Detail, scaled by the local field so it dies out at the foot.
		if (P.detail > 0.0) {
			const PackedFloat32Array nz = fractal_grid(p_gw, p_gh, p_rect, FRACTAL_STYLE_CRAGGY, 1.0,
					P.peak_spacing / 4.0, 5, 2.0, 0.5, 1.0, P.seed, 0.0, 1.0, 1);
			if (nz.size() == n) {
				const float *np = nz.ptr();
				for (int i = 0; i < n; i++) {
					if (field[(size_t)i] > 0.0) field[(size_t)i] = std::max(field[(size_t)i] * (1.0 + P.detail * (double)np[i]), 0.0);
				}
			}
		}
	}

	PackedFloat32Array h, cr, va, fp;
	h.resize(n);
	cr.resize(n);
	va.resize(n);
	fp.resize(n);
	float *hw = h.ptrw();
	float *cw = cr.ptrw();
	float *vw = va.ptrw();
	float *fw = fp.ptrw();
	for (int i = 0; i < n; i++) {
		double a = 1.0;
		if (amt) a = std::isfinite(amt[i]) ? std::clamp((double)amt[i], 0.0, 1.0) : 0.0;
		const double f = a * field[(size_t)i];
		const double b = base ? (double)base[i] : 0.0;
		hw[i] = (float)(P.max_blend ? std::max(b, f) : b + f);
		if (base && !std::isfinite(base[i])) hw[i] = base[i];
		cw[i] = (float)(crest[(size_t)i] * a);
		fw[i] = (float)(foot[(size_t)i] * a);
		const double e = env[(size_t)i];
		vw[i] = (float)(e > 0.0 ? foot[(size_t)i] * a * std::clamp(1.0 - field[(size_t)i] / e, 0.0, 1.0) : 0.0);
	}
	out["height"] = h;
	out["crest"] = cr;
	out["valley"] = va;
	out["footprint"] = fp;
	return out;
}
