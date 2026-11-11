// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Coastal Erosion — cut cliffs back where the sea is exposed, build beaches where it is sheltered.
//
// A shaping model, not a wave simulation, and NOT mass-conserving (`deposit` is a look control, not the
// cut volume moved). Four steps, each reusing a shared kernel where one exists:
//
//   1. Distances, in metres, with the shared JFA distance transform: land cells to the nearest water
//      (d_sea), water cells to the nearest land (d_land). A cell next to the water reads one cell size.
//   2. Retreat. A land cell with d_sea < R = retreat * exposure is cut to a WAVE-CUT PLATFORM:
//          h' = min(h, sea_level - platform_depth * (1 - d_sea / R))
//      deepest at the old shoreline, rising to sea level at the new cliff toe. The ground just beyond R is
//      untouched, so a vertical cliff stands at the retreat line.
//   3. Cliff face. The shared talus projection relaxes the cut band to `cliff_angle`, so the face is steep
//      rather than a one-cell wall. Restricted to cells that were cut or border a cut.
//   4. Beaches. Within `beach_width` either side of the shoreline, ground below the beach profile is
//      raised toward it by deposit * (1 - exposure):
//          target(s) = sea_level + beach_height * s / beach_width,  s in [-beach_width/2, beach_width]
//      with s = +d_sea on land and -d_land on water. Only raises, never cuts.
//
// `exposure` is 0..1 per cell, normally Wave Exposure's output; empty reads as 1 everywhere. Inland cells
// read the exposure Wave Exposure carried to them, which fades over its `shore_reach`, so set that to at
// least twice `retreat` or the cut stops short of R.

#ifndef PASTURE_3D_COASTAL_EROSION_H
#define PASTURE_3D_COASTAL_EROSION_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// The sixteen-slot param block, in this order on both routes.
struct CoastalErosionParams {
	double sea_level = 0.0;
	double retreat = 30.0; // metres of cliff retreat at exposure 1
	double platform_depth = 1.5; // metres below sea level at the old shoreline
	double cliff_angle = 70.0; // degrees
	int cliff_iterations = 8;
	double beach_height = 1.0; // metres above sea level at the back of the beach
	double beach_width = 30.0; // metres inland of the shoreline
	double deposit = 1.0; // 0..1
};

CoastalErosionParams coastal_erosion_params_from(const float *p_params, int p_count);

// Returns {height, cut (metres removed), deposit (metres added)}, each gw*gh. NaN cells pass through.
Dictionary coastal_erosion_grid(const PackedFloat32Array &p_height, const PackedFloat32Array &p_exposure,
		int p_gw, int p_gh, const Rect2 &p_rect, const CoastalErosionParams &p_prm);

} // namespace godot

#endif // PASTURE_3D_COASTAL_EROSION_H
