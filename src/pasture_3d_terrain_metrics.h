// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Phase 3 — terrain metrics and structural shaping.
// PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §6.
//
// Three kernels that all measure the terrain against a LOCAL reference rather than an absolute one:
//   RelativeElevation — where a cell sits between its local basin floor and its local crest
//   SmoothFill        — raise concave ground toward a blurred reference, leaving ridges alone
//   RecastCliff       — push already-steep ground toward a stepped face, leaving gentle ground alone
//
// All radii are WORLD METRES. All slopes are metric gradients (metres per metre), never per-cell rises.

#ifndef PASTURE_3D_TERRAIN_METRICS_H
#define PASTURE_3D_TERRAIN_METRICS_H

#include <cmath>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// Sync with Pasture3DGraphNodeRelativeElevation.OutputUnits.
enum RelativeElevationUnits {
	RELATIVE_ELEVATION_NORMALISED = 0, // 0 on the local basin floor, 1 on the local crest
	RELATIVE_ELEVATION_METRES = 1, // metres above the local basin floor
};

// Sync with Pasture3DGraphNodeSmoothFill.Mode.
enum SmoothFillMode {
	SMOOTH_FILL_VALLEYS = 0,
	SMOOTH_FILL_HOLES = 1,
	SMOOTH_FILL_SMEAR_PEAKS = 2,
};

// Separable box mean over a metric radius, shared by SmoothFill and RecastCliff.
//
// Deliberately two 1D passes of DIRECT gathers rather than an incremental running sum. A running sum is
// O(1) per cell instead of O(w), but it accumulates and cancels in a different order than a GPU gather
// can, and the two would then disagree by more than float32 rounding on large radii. Matching the GPU
// exactly is worth more here than the constant factor.
PackedFloat32Array box_mean_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_radius_m);

PackedFloat32Array relative_elevation_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_radius_m, int p_units);

// Writes the deposition channel (metres added, before normalisation) into r_deposition when non-null,
// and the divisor used to normalise it into r_deposition_divisor. The divisor is part of the interface
// for the same reason it is on DistanceTransform: a normalised channel without it is not reproducible.
PackedFloat32Array smooth_fill_solve(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_mask,
		int p_gw, int p_gh, const Rect2 &p_rect, int p_mode, double p_radius_m, double p_k,
		double p_amount, PackedFloat32Array *r_deposition, double *r_deposition_divisor);

// The one metric gradient: central differences in world metres, one-sided (and over one cell) at the grid
// edge. False when the cell or any of its four neighbours is non-finite, and gx/gz are then untouched.
// Recast Cliff and Slope both call this; a second copy would drift the moment one of them changed an edge.
inline bool metric_gradient(const float *p_src, int p_gw, int p_gh, int p_ix, int p_iz, double p_dx, double p_dz,
		double &r_gx, double &r_gz) {
	const int i = p_iz * p_gw + p_ix;
	if (!std::isfinite(p_src[i])) return false;
	const int xm = p_ix > 0 ? p_ix - 1 : 0;
	const int xp = p_ix + 1 < p_gw ? p_ix + 1 : p_gw - 1;
	const int zm = p_iz > 0 ? p_iz - 1 : 0;
	const int zp = p_iz + 1 < p_gh ? p_iz + 1 : p_gh - 1;
	const double zxm = (double)p_src[(size_t)p_iz * p_gw + xm];
	const double zxp = (double)p_src[(size_t)p_iz * p_gw + xp];
	const double zzm = (double)p_src[(size_t)zm * p_gw + p_ix];
	const double zzp = (double)p_src[(size_t)zp * p_gw + p_ix];
	if (!std::isfinite(zxm) || !std::isfinite(zxp) || !std::isfinite(zzm) || !std::isfinite(zzp)) return false;
	r_gx = (zxp - zxm) / (double)((xp - xm) * p_dx);
	r_gz = (zzp - zzm) / (double)((zp - zm) * p_dz);
	return true;
}

// Slope in degrees (0..90) and aspect (compass bearing the ground faces, 0..360: 0 north = -Z, 90 east = +X;
// flat reads 0), from the surface optionally box-meaned at `p_scale_m` first. NaN where the gradient is
// undefined. Either output may be null.
void slope_solve(const PackedFloat32Array &p_surface, int p_gw, int p_gh, const Rect2 &p_rect, double p_scale_m,
		PackedFloat32Array *r_degrees, PackedFloat32Array *r_aspect);

// The Slope node (op 77): {degrees, mask, aspect}. Params: 0 min_angle, 1 max_angle, 2 falloff (degrees each
// side of the band, smoothstep; 0 = a hard band), 3 scale (metres; 0 = raw). Mask is 0 where degrees is NaN.
Dictionary slope_grid(const PackedFloat32Array &p_surface, int p_gw, int p_gh, const Rect2 &p_rect,
		const float *p_params, int p_count);

PackedFloat32Array recast_cliff_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, double p_talus_angle_deg, double p_radius_m,
		double p_amplitude, double p_gain, double p_direction_deg, double p_direction_spread_deg,
		double p_amount);

} // namespace godot

#endif // PASTURE_3D_TERRAIN_METRICS_H
