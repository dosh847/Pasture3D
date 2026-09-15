// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Leveler — flatten an area to a statistic of its own ground, or level it to a height, with a feathered
// wall OUTSIDE the area (PASTURE3D_GRAPH_LEVELER_SPEC.md).
//
// ---- THE ORACLE IS THE DEFINITION ----
//
// Pasture3DGraphNodeDevLeveler (project/addons/pasture_3d/graph/pasture3d_graph_node_dev_leveler.gd) decides
// every rule a second implementation could pick differently, and this file mirrors each of them rather
// than choosing again:
//
//   * A NON-FINITE HEIGHT is outside the area and outside every statistic. A brush evaluates its graph with
//     no mask and composites through its own footprint, so cells outside the footprint arrive as NaN height —
//     that is the footprint rule, and there is no other.
//   * The MEAN is summed per row and folded in fixed 64-row blocks, in block order — never in chunk order,
//     so the answer is the same at one thread and at N.
//   * The MEDIAN is the LOWER median (rank ceil(N/2)) by a histogram over [min, max]: the first bin whose
//     cumulative count reaches N/2, interpolated within the bin. Bin counts are integers, so merging
//     per-thread histograms in any order is exact.
//   * The distance route is chosen by the AREA: a closed loop with a trivial mask measures exactly to the
//     polygon; anything a mask shapes measures by the Distance Transform's JFA from the core. The mask is
//     trivial when it is >= 1-1e-6 on every finite cell — the unwired default is 1, so an unwired mask and a
//     mask of 1 cannot be told apart, and the rule does not try.
//   * The falloff LUT is sampled linearly (the raster_ramp rule) in double.
//   * An EMPTY CORE passes the height through, every mask 0, level_value NaN.

#ifndef PASTURE_3D_LEVELER_H
#define PASTURE_3D_LEVELER_H

#include "pasture_3d_path_query.h"

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// Sync with Pasture3DGraphNodeLevelerBase's enums.
enum LevelerMode {
	LEVELER_FLATTEN = 0,
	LEVELER_LEVEL_AT_HEIGHT = 1,
};

enum LevelerStatistic {
	LEVELER_MEAN = 0,
	LEVELER_MEDIAN = 1,
	LEVELER_MIN = 2,
	LEVELER_MAX = 3,
};

enum LevelerCutFill {
	LEVELER_BOTH = 0,
	LEVELER_CUT_ONLY = 1,
	LEVELER_FILL_ONLY = 2,
};

enum LevelerWallsShape {
	LEVELER_BAND = 0,
	LEVELER_SLOPE = 1,
};

enum LevelerFeatherSide {
	LEVELER_INSIDE = 0, // the wall is built within the area, from its edge inward (the default)
	LEVELER_OUTSIDE = 1,
};

// MUST match Pasture3DGraphNodeLevelerBase.MEAN_BLOCK_ROWS and CORE_EPS.
constexpr int LEVELER_MEAN_BLOCK_ROWS = 64;
constexpr double LEVELER_CORE_EPS = 1.0e-6;

struct Pasture3DLevelerParams {
	int mode = LEVELER_FLATTEN;
	int statistic = LEVELER_MEAN;
	double target_height = 0.0; // world Y, LEVEL_AT_HEIGHT only; slot 2 is driven by the target socket
	int cut_fill = LEVELER_BOTH;
	double feather = 5.0; // metres, outside the area
	bool feather_from_path_width = false;
	double path_width_scale = 1.0;
	int walls_shape = LEVELER_BAND;
	double wall_depth = 1.0;
	int median_bins = 4096;
	int feather_side = LEVELER_INSIDE;
};

// The sixteen-slot block, unpacked. The ONLY reader of the slot order, on both routes — the Pasture3DUtil
// binding and GRAPH_OP_LEVELER — so the order is written once. Pasture3DGraphNodeLeveler.native_lower is
// the writer.
Pasture3DLevelerParams leveler_params_from(const float *p_params, int p_count);

// Level `p_height`. `p_loop` may be null, empty or open — all three mean "no loop". `p_mask` may be empty,
// which reads as 1 everywhere. `p_lut` is the 256-entry falloff (x = 0 at the area edge, 1 at the feather
// edge); an empty LUT bakes the analytic default 1 - smoothstep.
//
// Returns { ok, height, level_mask, level_value, delta, walls, core_count, level }. ok is false only for a
// degenerate grid or a height grid of the wrong size.
Dictionary leveler_grid_geom(const Pasture3DPathGeom *p_loop, const PackedFloat32Array &p_height,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh, const Rect2 &p_rect,
		const PackedFloat32Array &p_lut, const Pasture3DLevelerParams &p_params);

// The Pasture3DUtil entry point: the function above with a geometry build in front of it, closed exactly
// as the geometry table closes a ring.
Dictionary leveler_grid(const PackedVector2Array &p_points, const PackedFloat32Array &p_widths,
		bool p_closed, const PackedFloat32Array &p_height, const PackedFloat32Array &p_mask, int p_gw,
		int p_gh, const Rect2 &p_rect, const PackedFloat32Array &p_lut,
		const Pasture3DLevelerParams &p_params);

} // namespace godot

#endif // PASTURE_3D_LEVELER_H
