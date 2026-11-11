// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Generate Range Splines — crest lines for Path Range, laid out inside a closed outline (an island's coast).
// Spec: PASTURE3D_RANGES_SPEC.md, step 3. Output is a multi-part PATH (`part_starts`), one part per crest.
//
// Every mode reads the outline's INSIDE DISTANCE D(p): the exact distance to the outline (the shared
// Pasture3DPathGeom query) where p is inside it by the even-odd rule, negative outside.
//
//   SPINE    the medial axis. D is sampled on a `resolution`-cell grid over the outline's box; a cell is
//            medial when it and a 4-neighbour have nearest outline points more than ARC_RATIO · D apart
//            ALONG THE OUTLINE (the shorter way round). That arc test is what makes a fractal coast give one
//            spine and not a tree of whiskers: a bump in the coast pulls the nearest point only a short arc
//            away, and a rectangle's corner branches sit exactly 2·D apart, below the 3·D cut. The marked
//            cells are thinned (Zhang-Suen) to a one-cell skeleton, branches shorter than `min_branch` are
//            pruned until none are left, and the skeleton is cut into parts longest-chain first, smoothed and
//            resampled every `step` metres.
//   FOLDS    `count` parallel crests along compass bearing `angle` (0 north = -Z, 90 east = +X), `spacing`
//            apart across it, centred on the outline's box, bent sideways by `wander` · spacing metres of the
//            shared 1D noise over a 4 · spacing wavelength.
//   SCATTER  up to `count` straight-ish ridges, `length` · (1 ± length_jitter) long, at bearing angle ±
//            angle_jitter, bent by `wander` · spacing like a Path Range spur, centred at seeded points with D >=
//            coast_inset, rejected when any sample comes within `spacing` of an accepted ridge. Placement
//            consumes the seed in a fixed order, so the same seed gives the same set.
//
// Then, for every mode: each part is clipped to D >= coast_inset (a crossing is bisected onto the inset
// line), runs shorter than `min_branch` are dropped, and each vertex gets a height: peak_height, times
// ss(D / depth_scale) when height_from_depth is set, so ranges stand taller deeper inland.
//
// Returns { points: PackedVector2Array, heights: PackedFloat32Array, part_starts: PackedInt32Array,
// max_depth: float, spacing, length, wander: float } — max_depth is the outline's deepest inside distance
// (64² samples over its box), so a caller can say WHY nothing came out; spacing / length / wander are the
// layout actually used, in metres.
//
// AUTO LAYOUT. Spacing and length of 0 are derived from the outline, so one set of defaults fits a 600 m
// hill outline and a 10 km island alike. With U = max_depth - coast_inset (the room inside the inset; the
// whole depth when the inset swallows it): spacing = 2U / count, so `count` crests share the usable width;
// length = 2U. Wander is always a fraction of the spacing. Any positive spacing or length is metres.
// An open or degenerate outline returns empty arrays.

#ifndef PASTURE_3D_RANGE_SPLINES_H
#define PASTURE_3D_RANGE_SPLINES_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

namespace godot {

enum RangeSplinesMode {
	RANGE_SPLINES_SPINE = 0,
	RANGE_SPLINES_FOLDS = 1,
	RANGE_SPLINES_SCATTER = 2,
};

// The sixteen-slot block, in slot order.
struct RangeSplinesParams {
	int mode = RANGE_SPLINES_SPINE; // 0
	double coast_inset = 50.0; // 1, metres
	int seed = 0; // 2
	double peak_height = 600.0; // 3, metres
	double depth_scale = 500.0; // 4, metres
	bool height_from_depth = true; // 5
	double min_branch = 150.0; // 6, metres
	int count = 5; // 7
	double angle = 45.0; // 8, compass degrees
	double spacing = 0.0; // 9, metres; 0 = auto: 2 · (max_depth - coast_inset) / count
	double wander = 0.25; // 10, a fraction of the spacing
	double length = 0.0; // 11, metres; 0 = auto: 2 · (max_depth - coast_inset)
	double length_jitter = 0.4; // 12, fraction
	double angle_jitter = 30.0; // 13, degrees
	int resolution = 256; // 14, SPINE grid cells across the outline's longer side
	double step = 0.0; // 15, metres between output vertices; 0 = the outline's extent / 256
};

RangeSplinesParams range_splines_params_from(const float *p_params, int p_count);

Dictionary range_splines_solve(const PackedVector2Array &p_outline, bool p_closed, const RangeSplinesParams &p_params);

} // namespace godot

#endif // PASTURE_3D_RANGE_SPLINES_H
