// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace godot {

// Bench profile. SHARP is two linear segments meeting at a knee; SMOOTH is a power curve with an
// exponential foot. Both map [0,1] onto [0,1] and are the identity at gamma 1. A custom LUT (the node's
// CURVE mode) bypasses both. The GLSL twin is GKM_STRATA in pasture_3d_graph_gpu.cpp; the GDScript twin is
// Pasture3DGraphNodeStrata.profile().
enum StrataProfileMode {
	STRATA_PROFILE_SHARP = 0,
	STRATA_PROFILE_SMOOTH = 1,
};

// Lowered as P[8] = profile mode | flags. Bit 0 is the mode, so a mode-only P[8] reads unchanged.
enum StrataFlags {
	STRATA_FLAG_SMOOTH = 1,
	STRATA_FLAG_ELEVATION_MASK = 2,
};

// Hardness [0,1] to the profile gamma: 0 = identity (no benching), 1 = a strong ledge.
inline double strata_hardness_to_gamma(double p_hardness) {
	return 1.0 + (0.15 - 1.0) * std::clamp(p_hardness, 0.0, 1.0);
}

// The local gamma under lateral hardness variation, n = the break noise in [-1, 1]. A power, not a scale, so
// gamma 1 (hardness 0, the identity) stays the identity however much the hardness varies.
inline double strata_local_gamma(double p_gamma, double p_variation, double p_n) {
	return std::clamp(std::pow(p_gamma, 1.0 + p_variation * p_n), 0.05, 10.0);
}

inline double strata_profile(int p_mode, double p_u, double p_g) {
	const double u = std::clamp(p_u, 0.0, 1.0);
	if (p_mode == STRATA_PROFILE_SMOOTH) {
		return std::pow(u, p_g) * (1.0 - std::exp(-(50.0 / p_g) * u));
	}
	if (std::abs(p_g - 1.0) < 1.0e-3) {
		return u;
	}
	// The knee (a, b): the steep segment rises to b over [0, a], the shallow one covers the rest.
	const double a = std::pow(1.0 / p_g, 1.0 / (p_g - 1.0));
	const double b = std::pow(p_g, -p_g / (p_g - 1.0));
	return (u < a) ? u * b / a : b + (1.0 - b) * (u - a) / (1.0 - a);
}

// The elevation mask: 0 at or below p_lo, 1 at or above p_hi, linear between. A degenerate window is a step.
inline double strata_elevation_mask(double p_x, double p_lo, double p_hi) {
	if (p_hi <= p_lo) {
		return p_x >= p_lo ? 1.0 : 0.0;
	}
	return std::clamp((p_x - p_lo) / (p_hi - p_lo), 0.0, 1.0);
}

// ---- The outcrop mask --------------------------------------------------------------------------------
// Strata show as elongated outcrops, not an even skin. A cellular (Voronoi) field in a frame turned 45
// degrees off the dip direction, stretched 3:1 so cells run long, with the break noise wandering the long
// axis. F2 - F1 is small along cell borders and large in cell interiors: borders keep full strata,
// interiors fade by `strength`. Only position enters it, so the GPU route fills it on the host with this
// function. The hash is the Gavoronoise one (src/pasture_3d_gavoronoise.cpp), integer and exact.
inline uint32_t strata_hash_u32(uint32_t x) {
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

inline uint32_t strata_hash_cell(int32_t p_cx, int32_t p_cz, int32_t p_seed, uint32_t p_salt) {
	uint32_t h = strata_hash_u32((uint32_t)p_cx * 0x9e3779b1u);
	h = strata_hash_u32(h ^ ((uint32_t)p_cz * 0x85ebca6bu));
	h = strata_hash_u32(h ^ (uint32_t)p_seed);
	return strata_hash_u32(h ^ p_salt);
}

// The outcrop factor in [1 - strength, 1]. p_cos / p_sin: the dip direction. p_nv: the break noise.
inline double strata_outcrop(double p_wx, double p_wz, double p_cos, double p_sin, double p_nv,
		double p_size, double p_strength, int p_seed) {
	if (p_strength <= 0.0) {
		return 1.0;
	}
	const double size = std::max(p_size, 0.01);
	// The long axis: the dip direction turned 45 degrees. cos/sin(a + 45) from cos/sin(a).
	const double k = 0.70710678118654752;
	const double lc = (p_cos - p_sin) * k;
	const double ls = (p_sin + p_cos) * k;
	const double u = (p_wx * lc + p_wz * ls) / size + 0.4 * p_nv;
	const double v = (p_wx * p_cos + p_wz * p_sin) / (size / 3.0);
	const int cu = (int)std::floor(u);
	const int cv = (int)std::floor(v);
	double f1 = 1.0e30;
	double f2 = 1.0e30;
	for (int dz = -1; dz <= 1; dz++) {
		for (int dx = -1; dx <= 1; dx++) {
			const int cx = cu + dx;
			const int cz = cv + dz;
			const double fx = (double)cx + (double)(strata_hash_cell(cx, cz, p_seed, 0x51u) & 0x00ffffffu) / 16777216.0;
			const double fz = (double)cz + (double)(strata_hash_cell(cx, cz, p_seed, 0x52u) & 0x00ffffffu) / 16777216.0;
			const double d = std::sqrt((u - fx) * (u - fx) + (v - fz) * (v - fz));
			if (d < f1) {
				f2 = f1;
				f1 = d;
			} else if (d < f2) {
				f2 = d;
			}
		}
	}
	const double edge = std::clamp(f2 - f1, 0.0, 1.0);
	return 1.0 - std::clamp(p_strength, 0.0, 1.0) * edge;
}

PackedFloat32Array strata_grid(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_band_height, double p_hardness,
		double p_amount, double p_dip, double p_dip_direction_deg,
		double p_break_amount, double p_break_size, int p_seed,
		const PackedFloat32Array &p_profile_lut = PackedFloat32Array(),
		int p_profile_mode = STRATA_PROFILE_SHARP, double p_hardness_variation = 0.0,
		int p_octaves = 1, double p_lacunarity = 2.0,
		double p_mask_low = 0.0, double p_mask_high = 0.0, double p_outcrop_strength = 0.0,
		double p_outcrop_size = 180.0);

} // namespace godot
