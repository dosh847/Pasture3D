// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Path Range — a crest line turned into a mountain range: varied peaks along the crest, spurs raking off
// both sides, valleys forming between the spurs. Spec: PASTURE3D_RANGES_SPEC.md, step 1.
//
//   crest     hc(s) = base(s) · taper(s) · max(0, 1 + peak_variation · n1(s / peak_spacing))
//             base = peak_height, or the path's own heights when use_path_heights is set and it has them.
//             taper eases to end_height · base over end_taper metres at each OPEN end (a closed crest is a
//             ring range and has no ends). n1 is seeded 1D value-noise fBm over arc length in metres.
//   spurs     every spur_spacing metres (±25 % jitter), alternating sides (side flips each spur; the first
//             side is seeded). Direction = the crest normal rotated by spur_angle ± spur_angle_jitter back
//             toward the crest's start, so spurs rake like interfluves. Length = spur_length · (0.6 + 0.8 r)
//             · hc / peak_height. A spur's height runs from SPUR_ROOT · hc at its root down to 0 at its tip,
//             along a cosine. spur_wander bends it sideways with the same 1D noise. spur_levels 2 grows one
//             more level off each spur at half the spacing, length and height.
//   field     each line L contributes h_L(s) · xsec(d / hw), hw = max(width_ratio · h_L(s), MIN_HALF_WIDTH)
//             so a ridge is as steep at 50 m as at 500 m. xsec is ROUND (0.5 + 0.5 cos πx, Path Carve's
//             analytic default), SHARP ((1 - x)²) or FLAT (1 to x = 0.4, smoothstep down to 1).
//             Lines merge by a smooth max with radius min(blend_k, smaller value), so two ridges meet with
//             no crease and a ridge fading to 0 adds nothing (a plain smooth max would lift the background).
//   texture   none. Compose it downstream: a Fractal × footprint (or × height) added after the range.
//   result    input + amount · field (ADD) or max(input, amount · field) (MAX).
//
// Outputs: height, crest (max line coverage, 1 on a line falling to 0 at its half-width), valley (inside
// the footprint, 1 - field / envelope, envelope the tallest line height reaching the cell), footprint
// (inside any line's half-width, soft edge).
//
// Lines are generated in C++ from the crest, deterministic in seed. A line is evaluated as the max over its
// segments of each one's clamped-projection profile (not the single nearest point, which steps the height
// across a bend's medial axis). Each line rasterises only over its own bounding box plus reach.

#ifndef PASTURE_3D_PATH_RANGE_H
#define PASTURE_3D_PATH_RANGE_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

struct Pasture3DPathGeom;

enum PathRangeCrestShape {
	PATH_RANGE_ROUND = 0,
	PATH_RANGE_SHARP = 1,
	PATH_RANGE_FLAT = 2,
};

// The sixteen-slot param block, in this order on both routes. Slot 15 packs three switches:
// crest_shape (0..2) + 4 · max_blend + 8 · use_path_heights.
struct PathRangeParams {
	double peak_height = 300.0; // metres
	double peak_spacing = 600.0; // metres, wavelength of the crest's height variation
	double peak_variation = 0.5;
	double end_taper = 400.0; // metres
	double end_height = 0.2; // fraction of the crest height at an open end
	double width_ratio = 2.5; // half-width per metre of height
	double spur_spacing = 250.0; // metres
	double spur_length = 500.0; // metres
	double spur_angle = 25.0; // degrees raked back from the normal
	double spur_angle_jitter = 15.0; // degrees
	double spur_wander = 0.3; // sideways bend as a fraction of spur length
	int spur_levels = 1; // 0..2
	double blend_k = 40.0; // metres
	// slot 13 retired (was detail); ignored on read
	int seed = 0;
	int crest_shape = PATH_RANGE_ROUND;
	bool max_blend = false;
	bool use_path_heights = false;
};

PathRangeParams path_range_params_from(const float *p_params, int p_count);

// Returns {height, crest, valley, footprint}, each gw*gh. p_base and p_amount may be empty (0 and 1).
// An empty crest returns the base unchanged and zero masks.
Dictionary path_range_grid_geom(const Pasture3DPathGeom *p_crest, const PackedFloat32Array &p_base,
		const PackedFloat32Array &p_amount, int p_gw, int p_gh, const Rect2 &p_rect, const PathRangeParams &p_prm);

} // namespace godot

#endif // PASTURE_3D_PATH_RANGE_H
