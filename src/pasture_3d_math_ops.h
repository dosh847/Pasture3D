// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

// Falloff's shapes are GraphDistanceMetric 0-3; there is no separate falloff enum to keep in step.
#include "pasture_3d_distance_metric.h"

namespace godot {

// Sync with Pasture3DGraphNodeContrast.Mode.
enum GraphContrastMode {
	GRAPH_CONTRAST_GAIN = 0,
	GRAPH_CONTRAST_GAMMA = 1,
};

enum GraphMaskProperty {
	GRAPH_MASK_SLOPE = 0,
	GRAPH_MASK_ALTITUDE = 1,
	GRAPH_MASK_CURVATURE = 2,
};

PackedFloat32Array curve_grid(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_lut,
		double p_in_min, double p_in_max, double p_out_min, double p_out_max, double p_amount);

PackedFloat32Array remap_grid(const PackedFloat32Array &p_surface,
		double p_in_min, double p_in_max, double p_out_min, double p_out_max,
		bool p_clamp_output, double p_soft_knee, bool p_invert);

// Falloff (spec §4.2). Distance is measured in WORLD METRES from p_centre, never in grid fractions.
// p_noise is an optional per-cell distance perturbation grid; pass an empty array for none.
PackedFloat32Array falloff_grid(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_noise,
		int p_gw, int p_gh, const Rect2 &p_rect, int p_shape, double p_centre_x, double p_centre_z,
		double p_radius, double p_feather, double p_strength, bool p_invert, double p_distance_noise);

// Contrast (spec §4.3). Gain / gamma on a height WINDOW, because Pasture3D heights are metres and a raw
// pow() on a metre value is meaningless (and NaN for negative terrain).
// `p_explicit_window` false = auto-window to the surface's own finite min/max for this call (the default
// authoring mode); true = use p_range_min/p_range_max verbatim, in metres.
PackedFloat32Array contrast_grid(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_mask,
		int p_mode, double p_amount, double p_range_min, double p_range_max, double p_mask_amount,
		bool p_explicit_window);

// Float to Mask. `p_params` (Pasture3DGraphNodeFloatToMask.native_lower order): 0 range mode (0 fixed,
// 1 auto percentile), 1-2 fixed window, 3-4 auto low/high percentile (0..100), 5 invert, 6 gamma,
// 7 smoothstep, 8 blur passes. Non-finite input cells read 0. The percentile is the nearest rank over the
// finite cells, computed in double so the GDScript oracle can agree with it exactly.
PackedFloat32Array float_to_mask_grid(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const PackedFloat32Array &p_params);

// Gradient (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md §4). `p_params` is the node's resolved 16-slot block:
// 0 shape, 1-4 start/end in NODE space, 5-6 height min/max, 7 profile, 8 hardness, 9 repeat, 10 invert,
// 11 output mode, 12 distance_noise, 13-15 host origin x/z and yaw. `p_warp` may be empty (no warp).
PackedFloat32Array gradient_grid(const PackedFloat32Array &p_warp, int p_gw, int p_gh, const Rect2 &p_rect,
		const float *p_params, const PackedFloat32Array &p_lut);

// The world-space frame both the CPU kernel and the GPU planner derive from the params, once, in double.
struct GradientFrame {
	double ax = 0.0, az = 0.0, ux = 1.0, uz = 0.0, len = 1.0e-3;
	int metric = 0;
};
GradientFrame gradient_frame(const float *p_params);

// Value Ramp (spec §6). `p_params`: 0 stop count, 1 interpolation mode, 2 colour space, 3 channel, 4-5 input
// window, 6 repeat, 7 output mode, 8-9 height min/max, 10 amount. `p_stops` is [offset, r, g, b, a] x count.
PackedFloat32Array value_ramp_grid(const PackedFloat32Array &p_surface, const float *p_params,
		const PackedFloat32Array &p_stops);

PackedFloat32Array mask_grid(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, int p_property, double p_band_min, double p_band_max,
		double p_falloff_lo, double p_falloff_hi, bool p_invert, double p_strength);

} // namespace godot
