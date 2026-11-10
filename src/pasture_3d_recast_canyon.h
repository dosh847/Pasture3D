// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Recast Canyon — reshape the ground below a cut height with a power curve.
//
// After Hesiod/HighMap's recast_canyon, which on a [0,1] heightmap writes z < vcut as vcut * (z / vcut)^gamma
// and leaves everything above vcut alone. Pasture3D works in absolute metres, where sea level is not the
// bottom of anything, so the curve here runs between a FLOOR and the CUT rather than between 0 and vcut:
//
//     t  = (z - floor) / (cut - floor)        for floor < z < cut
//     z' = floor + (cut - floor) * t^gamma
//
// With floor = 0 and heights in [0,1] that is HighMap's formula exactly. Ground at or above the cut, and at
// or below the floor, passes through, and the curve meets both ends, so there is no step at either.
//
// gamma > 1 drops the middle of the band toward the floor: flat canyon floors under steep rims (HighMap's
// use). gamma < 1 lifts it toward the cut: the walls get steepest AT THE FLOOR, the inner-gorge profile of
// a valley that is cutting down faster than its sides can follow.

#ifndef PASTURE_3D_RECAST_CANYON_H
#define PASTURE_3D_RECAST_CANYON_H

#include <godot_cpp/variant/packed_float32_array.hpp>

namespace godot {

// p_noise, when supplied, is added to the cut height per cell (metres), as HighMap's noise overload does,
// so the rim line need not be a contour. It may be empty, and a NaN noise cell reads as 0. p_amount is
// clamped to [0,1].
PackedFloat32Array recast_canyon_solve(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_noise,
		int p_gw, int p_gh, double p_cut_height, double p_floor_height, double p_gamma, double p_amount);

} // namespace godot

#endif // PASTURE_3D_RECAST_CANYON_H
