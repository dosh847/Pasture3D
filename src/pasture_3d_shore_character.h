// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Shore Character — where a coast would be cliffed and where it would be a beach, from coastal signals.
// Spec: PASTURE3D_SHORE_CHARACTER_SPEC.md, step 2.
//
// Every signal is 0..1 with HIGHER meaning MORE CLIFF:
//
//   shape      headland vs bay. f = mean land fraction over two square windows (bay_radius, cove_radius)
//              by the shared box_mean_solve; shape = smoothstep(1 - f). A shore inside a bay is mostly
//              surrounded by land (f > 0.5, beach); a headland mostly by water (f < 0.5, cliff).
//   exposure   the `exposure` input as is (empty reads 1).
//   backshore  how high the ground near the shore stands: the mean height above sea of LAND cells within
//              backshore_dist (box_mean_solve of the land-only height over the land fraction), over
//              backshore_height, clamped. A tall hinterland gives cliffs; a low one gives beaches.
//
//   cliff_raw = Σ wᵢ·signalᵢ / Σ wᵢ;   cliff = smoothstep((cliff_raw - threshold)/softness + 0.5)
//   beach     = 1 - cliff
//   hardness  = clamp(0.5 + 0.5·hardness_variation·noise, 0, 1), noise the shared fractal_grid (fBm, world
//               metres, wavelength hardness_scale), so it does not move with resolution
//   erosion   = exposure · (1 - hardness)   — what Coastal Erosion's `exposure` port is meant to read
//
//   carry      cliff_raw is scored at the SHORELINE (land cells touching water) and every land cell within
//              carry_reach takes the score of its nearest shore cell (shared JFA, distance_transform_nearest).
//              A Coast Profile reads `cliff` across its whole rise, inland of the shore, where the per-cell
//              signals all lean to beach (more land around, less exposure). Carrying makes a cell on the
//              rise read the coast it belongs to. carry_reach 0 is the per-cell score, as originally built.
//              Only cliff/beach are carried; hardness and erosion stay per cell.
//              Nearest-shore carry is a step at every seam between shore cells (and at carry_reach), and
//              Coast Profile turns a step in cliff into a step in HEIGHT everywhere inland (its inland ramp
//              starts at beach + rise width, which cliff sets). So the carried score is then box-meaned over
//              land cells within carry_smooth (shared box_mean_solve). carry_smooth 0 leaves the steps.
//
// The outputs are defined everywhere but only meaningful within about bay_radius of the shore.
// Known limit: no valley-mouth signal. A native op takes one aux grid, and `exposure` uses it; fold a flow
// mask into the exposure upstream if valley mouths should read as beaches.

#ifndef PASTURE_3D_SHORE_CHARACTER_H
#define PASTURE_3D_SHORE_CHARACTER_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// The sixteen-slot param block, in this order on both routes.
struct ShoreCharacterParams {
	double sea_level = 0.0;
	int seed = 0;
	double bay_radius = 300.0; // metres
	double cove_radius = 60.0;
	double shape_weight = 1.0;
	double exposure_weight = 0.7;
	double backshore_weight = 0.5;
	double backshore_dist = 80.0; // metres
	double backshore_height = 40.0; // metres above sea that reads fully cliff
	double threshold = 0.5;
	double softness = 0.2;
	double hardness_scale = 400.0; // metres
	double hardness_variation = 0.6; // 0..1
	double carry_reach = 200.0; // metres inland a shoreline score is carried; 0 = per cell
	double carry_smooth = 50.0; // metres, box-mean radius over land applied to the carried score
};

ShoreCharacterParams shore_character_params_from(const float *p_params, int p_count);

// Returns {cliff, beach, hardness, erosion}, each gw*gh and 0..1. p_exposure may be empty (reads 1).
Dictionary shore_character_grid(const PackedFloat32Array &p_height, const PackedFloat32Array &p_exposure,
		int p_gw, int p_gh, const Rect2 &p_rect, const ShoreCharacterParams &p_prm);

} // namespace godot

#endif // PASTURE_3D_SHORE_CHARACTER_H
