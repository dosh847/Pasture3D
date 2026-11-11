// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Wave Exposure — how much open water each cell faces, from a heightfield and a sea level.
//
// FETCH is the coastal-engineering measure: the distance of open water upwind of a point. A headland facing
// the open sea has a long fetch from many directions; the back of a cove has a short one from all of them.
// Exposure is the fetch, capped at `max_fetch` and normalised, averaged over K directions with an optional
// prevailing-wind weighting.
//
// ---- ONE SWEEP PER DIRECTION, NOT A RAY PER CELL ----
//
// A ray march per cell per direction is O(N * K * max_fetch/dx). The fetch obeys a recurrence instead:
//
//     F[c] = water(c) ? L + F(c + u*step) : 0
//
// so visiting cells in the order the upwind neighbour is reached first makes it O(N * K). The step is the
// unit upwind vector scaled so its larger component is exactly one cell: the predecessor then always lies in
// the previous row or column (never the cell itself), and is read bilinearly from cells already written.
// Axis directions are exact; oblique ones carry the bilinear's smoothing, which is the price of O(N).
//
// ---- LAND CELLS CARRY THEIR SHORE'S EXPOSURE INLAND ----
//
// A cliff is several cells wide, but only the first land cell has water upwind. Land cells therefore inherit
// the exposure of the shore upwind of them (the same recurrence over a second array), faded to zero over
// `shore_reach` metres of land. The lee shore faces land upwind and reads 0.
//
// Cells outside the grid are open sea at `max_fetch` when `edge_open`, else land.

#ifndef PASTURE_3D_WAVE_EXPOSURE_H
#define PASTURE_3D_WAVE_EXPOSURE_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// The sixteen-slot param block, in this order on both routes.
struct WaveExposureParams {
	double sea_level = 0.0;
	double max_fetch = 3000.0; // metres
	int directions = 16;
	double wind_direction = 0.0; // degrees the wind comes FROM; 0 = north (-Z), 90 = east (+X)
	double wind_strength = 0.0; // 0 = all directions equal, 1 = only the upwind half counts
	double shore_reach = 40.0; // metres of land the shore's exposure carries inland
	bool edge_open = true;
};

WaveExposureParams wave_exposure_params_from(const float *p_params, int p_count);

// Returns {exposure (0..1), fetch (metres)}, each gw*gh. NaN height cells are land and read 0.
Dictionary wave_exposure_grid(const PackedFloat32Array &p_height, int p_gw, int p_gh, const Rect2 &p_rect,
		const WaveExposureParams &p_prm);

} // namespace godot

#endif // PASTURE_3D_WAVE_EXPOSURE_H
