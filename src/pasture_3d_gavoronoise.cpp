// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
// Erosion stage after Clay John (MIT), base after Inigo Quilez (MIT) — see the header for both notices.

#include "pasture_3d_gavoronoise.h"
#include "pasture_3d_graph_ops.h"
#include "pasture_3d_terrain_metrics.h"
#include "pasture_3d_thread_pool.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

using namespace godot;

namespace {

constexpr double kTau = 6.283185307179586;
constexpr int kBaseOctaves = 8;
constexpr double kGradEps = 0.1; // the generator's central-difference step, in p units
constexpr uint32_t kErosionSeed = 0x9e3779b9u;

// A uint32 multiply-xor-shift hash. Integer, deliberately: see the header.
inline uint32_t hash_u32(uint32_t x) {
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

inline uint32_t hash_cell(int32_t p_cx, int32_t p_cz, uint32_t p_seed, uint32_t p_salt) {
	uint32_t h = hash_u32((uint32_t)p_cx * 0x9e3779b1u);
	h = hash_u32(h ^ ((uint32_t)p_cz * 0x85ebca6bu));
	h = hash_u32(h ^ p_seed);
	return hash_u32(h ^ p_salt);
}

// 24 bits into [0,1). 24 is the float mantissa, so this conversion is exact on the GPU too.
inline double rnd01(uint32_t p_h) {
	return (double)(p_h & 0x00ffffffu) / 16777216.0;
}

inline double smoothstep01(double p_lo, double p_hi, double p_x) {
	if (p_hi - p_lo <= 1e-9) {
		return p_x >= p_hi ? 1.0 : 0.0;
	}
	const double t = std::clamp((p_x - p_lo) / (p_hi - p_lo), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

double gabor(double p_x, double p_z, double p_kx, double p_kz, double p_spread, uint32_t p_seed) {
	const double flx = std::floor(p_x);
	const double flz = std::floor(p_z);
	const int32_t bx = (int32_t)flx;
	const int32_t bz = (int32_t)flz;
	const double fx = p_x - flx;
	const double fz = p_z - flz;
	double av = 0.0;
	double at = 0.0;
	for (int j = -2; j <= 2; j++) {
		for (int i = -2; i <= 2; i++) {
			const int32_t cx = bx + i;
			const int32_t cz = bz + j;
			const double rx = fx - ((double)i + rnd01(hash_cell(cx, cz, p_seed, 1u)));
			const double rz = fz - ((double)j + rnd01(hash_cell(cx, cz, p_seed, 2u)));
			double kx = p_kx + p_spread * (2.0 * rnd01(hash_cell(cx, cz, p_seed, 3u)) - 1.0);
			double kz = p_kz + p_spread * (2.0 * rnd01(hash_cell(cx, cz, p_seed, 4u)) - 1.0);
			const double kl = std::sqrt(kx * kx + kz * kz);
			if (kl > 1e-9) {
				kx /= kl;
				kz /= kl;
			} else {
				kx = p_kx;
				kz = p_kz;
			}
			const double w = std::exp(-4.0 * (rx * rx + rz * rz));
			av += w * std::cos(kTau * (rx * kx + rz * kz));
			at += w;
		}
	}
	return av / at;
}

double base_fbm(double p_x, double p_z, double p_kx, double p_kz, double p_spread, uint32_t p_seed) {
	double n = 0.0;
	double nf = 1.0;
	double na = 0.6;
	for (int o = 0; o < kBaseOctaves; o++) {
		const double v = gabor(p_x * nf, p_z * nf, p_kx, p_kz, p_spread, p_seed + (uint32_t)o * 7919u);
		n += v * na;
		na *= std::min(v + 1.0, 2.0) * 0.5;
		na *= 0.5;
		nf *= 2.0;
	}
	return n;
}

void eroder(double p_x, double p_z, double p_dx, double p_dz, uint32_t p_seed, double &r_v, double &r_gx,
		double &r_gz) {
	const double flx = std::floor(p_x);
	const double flz = std::floor(p_z);
	const int32_t bx = (int32_t)flx;
	const int32_t bz = (int32_t)flz;
	const double fx = p_x - flx;
	const double fz = p_z - flz;
	double va = 0.0;
	double vx = 0.0;
	double vz = 0.0;
	double wt = 0.0;
	for (int j = -2; j <= 2; j++) {
		for (int i = -2; i <= 2; i++) {
			const int32_t cx = bx + i;
			const int32_t cz = bz + j;
			const double rx = fx - ((double)i + 0.5 * rnd01(hash_cell(cx, cz, p_seed, 5u)));
			const double rz = fz - ((double)j + 0.5 * rnd01(hash_cell(cx, cz, p_seed, 6u)));
			const double w = std::exp(-2.0 * (rx * rx + rz * rz));
			const double ph = kTau * (rx * p_dx + rz * p_dz);
			va += w * std::cos(ph);
			const double s = -w * std::sin(ph);
			vx += s * p_dx;
			vz += s * p_dz;
			wt += w;
		}
	}
	r_v = va / wt;
	r_gx = vx / wt;
	r_gz = vz / wt;
}

// The erosion stage's value channel. p_base is the normalised base height (about -1..1), p_d* its
// along-contour direction in p units.
double erosion(double p_x, double p_z, double p_base, double p_dx, double p_dz, const GavoronoiseParams &p) {
	double hv = 0.0;
	double hx = 0.0;
	double hz = 0.0;
	double a = 0.6 * smoothstep01(p.z_cut_min, p.z_cut_max, p_base * 0.5 + 0.5);
	double f = 1.0;
	const int oct = std::clamp(p.octaves, 1, 12);
	for (int o = 0; o < oct; o++) {
		double ev, egx, egz;
		eroder(p_x * p.erosion_frequency * f, p_z * p.erosion_frequency * f, p_dx + p.branch_strength * hz, p_dz - p.branch_strength * hx,
				kErosionSeed + (uint32_t)p.seed + (uint32_t)o * 7919u, ev, egx, egz);
		hv += a * ev;
		hx += a * f * egx;
		hz += a * f * egz;
		a *= 0.4;
		f *= 2.0;
	}
	return hv;
}

} // namespace

PackedFloat32Array godot::gavoronoise_grid(int p_gw, int p_gh, const Rect2 &p_rect, const GavoronoiseParams &p) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	if (p_gw <= 0 || p_gh <= 0) {
		return out;
	}
	out.resize(n);
	if (std::abs(p.amplitude) <= 1e-7 || p.frequency <= 0.0) {
		out.fill(0.f);
		return out;
	}
	const double theta = p.angle_deg * kTau / 360.0;
	// The wave vector runs ACROSS the strike, so the crests run along it.
	const double kx = -std::sin(theta);
	const double kz = std::cos(theta);
	const double spread = std::clamp(p.angle_spread, 0.0, 1.0);
	const uint32_t seed = (uint32_t)p.seed;
	float *w = out.ptrw();

	Pasture3DThreadPool::parallel_for_rows(p_gh, 4, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				double wx, wz;
				graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, wx, wz);
				const double px = wx * p.frequency;
				const double pz = wz * p.frequency;
				const double b = base_fbm(px, pz, kx, kz, spread, seed);
				const double mx = base_fbm(px + kGradEps, pz, kx, kz, spread, seed)
						- base_fbm(px - kGradEps, pz, kx, kz, spread, seed);
				const double mz = base_fbm(px, pz + kGradEps, kx, kz, spread, seed)
						- base_fbm(px, pz - kGradEps, kx, kz, spread, seed);
				const double dx = mz / kGradEps * 0.5 * p.slope_strength;
				const double dz = -mx / kGradEps * 0.5 * p.slope_strength;
				const double v = b + p.erosion_strength * erosion(px, pz, b, dx, dz, p);
				w[iz * p_gw + ix] = (float)(p.amplitude * (0.5 * v + 0.5));
			}
		}
	});
	return out;
}

PackedFloat32Array godot::gavoronoise_base_grid(int p_gw, int p_gh, const Rect2 &p_rect, const GavoronoiseParams &p,
		const PackedFloat32Array &p_base, double p_base_smoothing_m) {
	const int n = p_gw * p_gh;
	if (p_gw <= 0 || p_gh <= 0 || p_base.size() != n) {
		return PackedFloat32Array();
	}
	if (std::abs(p.amplitude) <= 1e-7 || p.frequency <= 0.0 || p.erosion_strength == 0.0) {
		return p_base;
	}
	const PackedFloat32Array smoothed = p_base_smoothing_m > 0.0
			? box_mean_solve(p_base, p_gw, p_gh, p_rect, p_base_smoothing_m)
			: p_base;
	const float *src = p_base.ptr();
	const float *sm = smoothed.ptr();
	const double cell_dx = (double)p_rect.size.x / (double)p_gw;
	const double cell_dz = (double)p_rect.size.y / (double)p_gh;
	// Metres-per-metre slope into base-units per p-unit: base = 2 z / amplitude - 1, p = world * frequency.
	const double to_n = 2.0 / (p.amplitude * p.frequency);

	PackedFloat32Array out;
	out.resize(n);
	float *w = out.ptrw();
	Pasture3DThreadPool::parallel_for_rows(p_gh, 8, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = iz * p_gw + ix;
				const double z = (double)src[i];
				if (!std::isfinite(z)) {
					w[i] = src[i];
					continue;
				}
				const int xm = std::max(ix - 1, 0);
				const int xp = std::min(ix + 1, p_gw - 1);
				const int zm = std::max(iz - 1, 0);
				const int zp = std::min(iz + 1, p_gh - 1);
				const double a0 = (double)sm[iz * p_gw + xm];
				const double a1 = (double)sm[iz * p_gw + xp];
				const double b0 = (double)sm[zm * p_gw + ix];
				const double b1 = (double)sm[zp * p_gw + ix];
				double gx = 0.0;
				double gz = 0.0;
				if (std::isfinite(a0) && std::isfinite(a1) && std::isfinite(b0) && std::isfinite(b1)) {
					gx = (a1 - a0) / ((double)(xp - xm) * cell_dx) * to_n;
					gz = (b1 - b0) / ((double)(zp - zm) * cell_dz) * to_n;
				}
				double wx, wz;
				graph_cell_to_world(ix, iz, p_gw, p_gh, p_rect, wx, wz);
				const double bn = 2.0 * z / p.amplitude - 1.0;
				const double e = erosion(wx * p.frequency, wz * p.frequency, bn, gz * p.slope_strength,
						-gx * p.slope_strength, p);
				w[i] = (float)(z + p.erosion_strength * e * p.amplitude * 0.5);
			}
		}
	});
	return out;
}
