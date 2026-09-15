// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// The ONE C++ definition of the graph's distance metrics and repeat modes
// (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md §3).
//
// Falloff and Gradient both measure through this. The GLSL twin is GRAPH_DISTANCE_METRIC_GLSL in
// pasture_3d_graph_gpu.cpp, and the GDScript oracle is Pasture3DGraphDistance. The oracle is written
// independently rather than transcribed, so agreement between the three means something.
//
// ---- WHY A UNIT DIRECTION AND NOT AN END POINT ----
//
// Falloff has no end point, and it must stay BIT-IDENTICAL through this refactor. Handing it `b = a + (1, 0)`
// would make the metric compute `(ax + 1) - ax`, which is not exactly 1 once `ax` is large, and every
// SQUARE falloff away from the origin would move by a few ulps. So callers pass the direction already
// normalised: Falloff passes the literal (1, 0), for which the frame rotation below is exact, and Gradient
// derives it once per lowering with p3d_metric_direction().

#pragma once

#include <algorithm>
#include <cmath>

namespace godot {

// Serialised through Pasture3DGraphNodeFalloff.Shape (0-3) and Pasture3DGraphNodeGradient. Append only.
enum GraphDistanceMetric {
	GRAPH_METRIC_RADIAL = 0, // |p - a|
	GRAPH_METRIC_SQUARE = 1, // max(|x'|, |z'|) in the frame of u
	GRAPH_METRIC_AXIS_X = 2, // |dx|, world axis
	GRAPH_METRIC_AXIS_Z = 3, // |dz|, world axis
	GRAPH_METRIC_LINEAR = 4, // signed projection of (p - a) onto u
	GRAPH_METRIC_REFLECTED = 5, // |LINEAR|
	GRAPH_METRIC_DIAMOND = 6, // |x'| + |z'| in the frame of u
	GRAPH_METRIC_ANGULAR = 7, // atan2 sweep about a from u, in [0, 2pi). RADIANS, not metres.
};

enum GraphRepeatMode {
	GRAPH_REPEAT_CLAMP = 0,
	GRAPH_REPEAT_REPEAT = 1,
	GRAPH_REPEAT_MIRROR = 2,
};

// The unit direction from a to b. Under 1e-6 m apart the direction is undefined, and it is DEFINED here as
// +X, once, so Gradient's three evaluators cannot pick different fallbacks.
inline void p3d_metric_direction(double p_ax, double p_az, double p_bx, double p_bz, double &r_ux, double &r_uz) {
	const double vx = p_bx - p_ax;
	const double vz = p_bz - p_az;
	const double len = std::sqrt(vx * vx + vz * vz);
	if (!(len >= 1.0e-6)) {
		r_ux = 1.0;
		r_uz = 0.0;
		return;
	}
	r_ux = vx / len;
	r_uz = vz / len;
}

// Distance from world point (wx, wz) to origin (ax, az) under metric `p_metric`, with (ux, uz) a UNIT
// direction. Metres for every metric except ANGULAR (radians). An unknown metric is RADIAL, which is what
// Falloff's switch always did with an out-of-range shape.
//
// The frame is x' = along u, z' = u rotated a quarter turn. For u = (1, 0) both are exact copies of dx and
// dz (dx*1 + dz*0 adds a signed zero), which is what keeps SQUARE bit-identical for Falloff.
inline double p3d_distance_metric(int p_metric, double p_wx, double p_wz, double p_ax, double p_az,
		double p_ux, double p_uz) {
	const double dx = p_wx - p_ax;
	const double dz = p_wz - p_az;
	switch (p_metric) {
		case GRAPH_METRIC_AXIS_X:
			return std::abs(dx);
		case GRAPH_METRIC_AXIS_Z:
			return std::abs(dz);
		case GRAPH_METRIC_SQUARE:
		case GRAPH_METRIC_LINEAR:
		case GRAPH_METRIC_REFLECTED:
		case GRAPH_METRIC_DIAMOND:
		case GRAPH_METRIC_ANGULAR: {
			const double px = dx * p_ux + dz * p_uz;
			const double pz = dz * p_ux - dx * p_uz;
			switch (p_metric) {
				case GRAPH_METRIC_SQUARE:
					return std::max(std::abs(px), std::abs(pz));
				case GRAPH_METRIC_LINEAR:
					return px;
				case GRAPH_METRIC_REFLECTED:
					return std::abs(px);
				case GRAPH_METRIC_DIAMOND:
					return std::abs(px) + std::abs(pz);
				default: {
					double ang = std::atan2(pz, px);
					if (ang < 0.0) {
						ang += 2.0 * 3.14159265358979323846;
					}
					return ang;
				}
			}
		}
		case GRAPH_METRIC_RADIAL:
		default:
			return std::sqrt(dx * dx + dz * dz);
	}
}

// Fold a normalised coordinate by repeat mode. CLAMP to [0, 1]; REPEAT keeps the fractional part (so 1.0
// wraps to 0); MIRROR ping-pongs, 0 at even integers and 1 at odd ones. A non-finite t passes through, so a
// NaN hole stays a hole instead of becoming a clamped 0.
inline double p3d_repeat(int p_mode, double p_t) {
	if (!std::isfinite(p_t)) {
		return p_t;
	}
	switch (p_mode) {
		case GRAPH_REPEAT_REPEAT:
			return p_t - std::floor(p_t);
		case GRAPH_REPEAT_MIRROR: {
			const double h = p_t * 0.5;
			return 1.0 - std::abs((h - std::floor(h)) * 2.0 - 1.0);
		}
		case GRAPH_REPEAT_CLAMP:
		default:
			return std::clamp(p_t, 0.0, 1.0);
	}
}

} // namespace godot
