// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native PATH Operations (Reshape and Derive Families)
// Implements high-performance C++ algorithms for:
// - Derive Family (GRID -> PATH): PathDrape, PathWidthField, PathFromFlow
// - Reshape Family (PATH -> PATH): PathResample, PathSmooth, PathDecimate,
//                                 PathFractalize, PathMeanderize, PathWidth
// - Core Polyline Mechanics: arc lengths, segment projection, attribute lerp,
//                           grid bilinear sampling.

#ifndef PASTURE_3D_PATH_OPS_H
#define PASTURE_3D_PATH_OPS_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace godot {

// Maximum vertices limit matching GDScript MAX_POINTS
constexpr int PATH_OPS_MAX_POINTS = 200000;

// ---- Core Polyline & Field Geometry Helpers ---------------------------------

// Cumulative arc length at each vertex of p_pts in metres.
// If p_closed is true and p_pts has >= 2 points, returns n + 1 elements including closing segment.
PackedFloat32Array path_arc_lengths(const PackedVector2Array &p_pts, bool p_closed = false);

// Arc length of the point on polyline p_pts nearest to p_q.
// When p_closed is true, also checks the closing segment connecting the last vertex to the first.
double path_project_s(const PackedVector2Array &p_pts, const PackedFloat32Array &p_cum,
		const Vector2 &p_q, bool p_closed = false);

// Sample a per-vertex array at arc length p_s linearly.
// Returns NAN for an empty array. Wraps around seam on closed paths.
float path_sample_along(const PackedFloat32Array &p_vals, const PackedFloat32Array &p_cum,
		double p_s, bool p_closed = false);

// Project and carry widths and heights from p_src_pts onto p_dst_pts.
void path_carry_values(const PackedVector2Array &p_src_pts, const PackedFloat32Array &p_src_widths,
		const PackedFloat32Array &p_src_heights, bool p_src_closed,
		const PackedVector2Array &p_dst_pts, PackedFloat32Array &r_dst_widths,
		PackedFloat32Array &r_dst_heights);

// Bilinear sample of a grid at world XZ, matching Pasture3DGraphNodePathDerive::sample_grid.
// Returns NAN outside the domain rect or when any neighbor cell is non-finite.
float path_sample_grid(const PackedFloat32Array &p_grid, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_wx, double p_wz);

// Ring helpers for closed paths
PackedVector2Array path_ring_of(const PackedVector2Array &p_pts, bool p_closed);
PackedVector2Array path_unring(const PackedVector2Array &p_pts, bool p_closed);

// ---- Derive Family (GRID -> PATH) -------------------------------------------

// PathDrape: Sample surface elevation onto polyline vertices.
// Returns PackedFloat32Array of draped heights.
PackedFloat32Array path_drape_solve(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_existing_heights, bool p_closed,
		const PackedFloat32Array &p_grid, int p_gw, int p_gh, const Rect2 &p_rect,
		double p_offset, bool p_force_downhill, double p_min_drop);

// PathWidthField: Remap field values sampled at polyline vertices to half-widths.
// p_curve_lut: optional 256-float baked LUT (empty = linear [0,1]).
// Returns PackedFloat32Array of half-widths.
PackedFloat32Array path_width_field_solve(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_existing_widths,
		const PackedFloat32Array &p_field, int p_gw, int p_gh, const Rect2 &p_rect,
		double p_field_min, double p_field_max, double p_half_width_min, double p_half_width_max,
		const PackedFloat32Array &p_curve_lut, bool p_scale_existing, double p_min_half_width);

// PathFromFlow: Trace streamline uphill from accumulation outlet or seed point.
// Returns Dictionary with "points", "half_widths", "heights".
Dictionary path_from_flow_solve(const PackedFloat32Array &p_flow,
		const PackedFloat32Array &p_surface, int p_gw, int p_gh, const Rect2 &p_rect,
		int p_seed_mode, const Vector2 &p_seed_point, double p_seed_radius,
		double p_min_flow, int p_step_cells, int p_max_points, double p_half_width);

// ---- Reshape Family (PATH -> PATH) ------------------------------------------

// PathResample: Walk arc length and place vertices every p_step metres.
// p_method: 0 = LINEAR, 1 = CUBIC, 2 = CATMULL_ROM, 3 = BEZIER.
// Returns Dictionary with "points", "half_widths", "heights", "closed".
Dictionary path_resample_solve(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_widths, const PackedFloat32Array &p_heights,
		bool p_closed, int p_method, double p_step, bool p_close);

// PathSmooth: Moving average window with intensity and inertia lag.
// Returns Dictionary with "points", "half_widths", "heights".
Dictionary path_smooth_solve(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_widths, const PackedFloat32Array &p_heights,
		bool p_closed, int p_window, double p_intensity, double p_inertia, bool p_pin_ends);

// PathDecimate: Visvalingam-Whyatt area-based polyline simplification.
// Returns Dictionary with "points", "half_widths", "heights".
Dictionary path_decimate_solve(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_widths, const PackedFloat32Array &p_heights,
		bool p_closed, int p_target_points, double p_min_area);

// PathFractalize: Midpoint and normal displacement using 1D noise octaves.
// p_orientation: 0 = BOTH, 1 = LEFT, 2 = RIGHT.
// Returns Dictionary with "points", "half_widths", "heights".
Dictionary path_fractalize_solve(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_widths, const PackedFloat32Array &p_heights,
		bool p_closed, int p_orientation, double p_wavelength, double p_lacunarity,
		int p_iterations, double p_sigma, double p_persistence, int p_seed, bool p_pin_ends);

// PathMeanderize: Curvature amplification, noise jitter, edge subdivision, and loop excision.
// Returns Dictionary with "points", "half_widths", "heights".
Dictionary path_meanderize_solve(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_widths, const PackedFloat32Array &p_heights,
		bool p_closed, double p_wavelength, double p_amplitude, double p_ratio,
		double p_noise_ratio, int p_seed, int p_iterations, double p_min_segment_length,
		int p_edge_divisions, bool p_remove_loops, bool p_pin_ends);

// PathWidth: Rewrite half-widths by SET or SCALE with arc-length curve LUT.
// p_mode: 0 = SET, 1 = SCALE.
// Returns PackedFloat32Array of half-widths.
PackedFloat32Array path_width_solve(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_existing_widths, bool p_closed,
		int p_mode, double p_half_width, const PackedFloat32Array &p_along_lut,
		double p_min_half_width);

} // namespace godot

#endif // PASTURE_3D_PATH_OPS_H
