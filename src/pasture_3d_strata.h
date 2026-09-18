// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

#include <algorithm>
#include <cmath>

namespace godot {

// Bench profile. SHARP is two linear segments meeting at a knee; SMOOTH is a power curve with an
// exponential foot. Both map [0,1] onto [0,1] and are the identity at gamma 1. A custom LUT (the node's
// CURVE mode) bypasses both. The GLSL twin is GKM_STRATA in pasture_3d_graph_gpu.cpp; the GDScript twin is
// Pasture3DGraphNodeStrata.profile().
enum StrataProfileMode {
	STRATA_PROFILE_SHARP = 0,
	STRATA_PROFILE_SMOOTH = 1,
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

PackedFloat32Array strata_grid(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_band_height, double p_hardness,
		double p_amount, double p_dip, double p_dip_direction_deg,
		double p_break_amount, double p_break_size, int p_seed,
		const PackedFloat32Array &p_profile_lut = PackedFloat32Array(),
		int p_profile_mode = STRATA_PROFILE_SHARP, double p_hardness_variation = 0.0,
		int p_octaves = 1, double p_lacunarity = 2.0);

} // namespace godot
