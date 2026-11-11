// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Coast Profile — a closed island outline turned into a coastal cross-section.
//
// The pattern every node-based terrain tool uses for islands: a SIGNED distance from the shoreline
// (positive inland, negative at sea) pushed through a profile. Here the profile is parametric rather than a
// free curve, because each band is a thing a coast physically has and an artist wants to size in metres:
//
//   sea floor ── drop-off ── shelf ── | shoreline | ── beach ── cliff ── inland rise
//
//   d < 0 (sea, e = -d):  h = -shelf_depth·ss(e/shelf_width) - (floor_depth - shelf_depth)·ss((e - shelf_width)/drop_width)
//   d ≥ 0 (land):         h =  beach_height·ss(d/bw) + cliff_height·ss((d - bw)/w)
//                             + inland_height·ss(x)^inland_curve,  x = (d - bw - w)/inland_width
//
// with ss the smoothstep, c the per-cell cliff weight (the aux mask, 1 when unwired), bw = beach_width·(1 - c)
// and w = cliff_width·c + slope_width·(1 - c). Where the coast is cliffed the beach narrows to nothing, so
// the cliff stands in the water instead of behind a strand. c sets the rise's STEEPNESS, never its height:
// at any c the land reaches beach_height + cliff_height at d = bw + w, so a beach zone climbs to the plateau
// over slope_width instead of sinking into a trench. Every band meets its neighbour with zero slope, so no seam shows at a band boundary.
//
// Only a CLOSED path has an inside. An open or empty path reads as all sea, at floor depth — "no island"
// is open ocean, never sea level everywhere (which would be a flat continent at the waterline).

#ifndef PASTURE_3D_COAST_PROFILE_H
#define PASTURE_3D_COAST_PROFILE_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

struct Pasture3DPathGeom;

// The sixteen-slot param block, in this order on both routes (node native_lower and the binding).
struct CoastProfileParams {
	double shelf_depth = 6.0;
	double shelf_width = 250.0;
	double floor_depth = 80.0;
	double drop_width = 150.0;
	double beach_height = 1.5;
	double beach_width = 25.0;
	double cliff_height = 30.0;
	double cliff_width = 12.0;
	double inland_height = 80.0;
	double inland_width = 600.0;
	double inland_curve = 0.7;
	double sea_level = 0.0;
	double mask_feather = 4.0;
	double slope_width = 150.0; // rise width where the cliff weight is 0; clamped >= cliff_width
};

CoastProfileParams coast_profile_params_from(const float *p_params, int p_count);

// Returns {height, signed_distance, shelf, beach, cliff}, each gw*gh. p_cliff may be empty (reads as 1).
Dictionary coast_profile_grid_geom(const Pasture3DPathGeom *p_geom, const PackedFloat32Array &p_cliff,
		int p_gw, int p_gh, const Rect2 &p_rect, const CoastProfileParams &p_prm);

} // namespace godot

#endif // PASTURE_3D_COAST_PROFILE_H
