// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

struct HydraulicSaleveParams {
	// Upper bound on Stage 1 passes; the solve stops earlier once it converges below `tolerance`.
	int iterations = 200;
	// Mean |dz| per pass, as a fraction of the current relief, below which Stage 1 has converged.
	float tolerance = 1.0e-3f;
	float erosion_strength = 0.7f;
	float drainage_exponent = 0.15f;
	float drainage_noise = 0.15f;
	float shape_preservation = 2.0f;
	// The vertical scale (metres) every length in the solver is measured against, so the drainage network
	// is a property of the TERRAIN and not of the grid it happens to be solved on. 0 = take it from the
	// input's own relief (zmax - zmin), which is convenient but moves whenever the solved extent changes
	// — most visibly under a brush's Modifier Margin, where the band brings surrounding ground into range.
	// Pin it to hold a shape steady across margins, resizes and re-bakes.
	float reference_relief = 0.0f;
	float bank_smoothing = 0.0f;
	// Radial slope limit (dimensionless, m/m): `max_slope_center` at the domain centre falling to
	// `max_slope_border` at a distance of the smaller domain side, along 1 - r^2(3 - 2r).
	float max_slope_center = 6.0f;
	float max_slope_border = 0.0f;
	int seed = 0;
	PackedFloat32Array mask;
	PackedFloat32Array dx;
	PackedFloat32Array dy;

	// Coarse irregular solve (S2). Stage 1 runs on jittered control points triangulated by Delaunay, then is
	// reconstructed onto the grid. `point_spacing` (metres) wins when > 0 and pins the point lattice to the
	// world, so a margin adds points without moving any; 0 derives it from `control_points` over the rect.
	int control_points = 15000;
	float point_spacing = 0.0f;
	// 0 LINEAR (barycentric), 1 GRADIENT (per-vertex gradients blended by squared barycentrics).
	// 2 NEAREST is a gate control only.
	int reconstruction = 1;
	// dx/dy (metres) warp the reconstruction's sample position; `default_warp` ADDS seeded fBm on top, so an
	// unwired port (absent or a zeros grid, the two evaluators disagree which) means the same thing.
	bool default_warp = true;
	float warp_amount = 0.0f; // metres; 0 = 2% of the smaller rect side
	float warp_size = 0.0f; // metres; 0 = a quarter of the smaller rect side

	// Stage 2: deposition. Priority-flood fill of the reconstructed grid, blended toward a blur of the fill
	// on flat ground; only ever raises cells, and is zero where nothing holds water. Radius in METRES,
	// 0 = 10% of the smaller rect side.
	float deposition_radius = 0.0f;
	float deposition_strength = 0.5f;

	// Stage 3: fine incision IS the stream-log solver (hydraulic_stream_log_solve) on the grid, in metres.
	// stream_strength -> incision_rate, stream_exp -> area_exponent; 0 strength skips it.
	float stream_strength = 0.15f;
	float stream_exp = 0.5f;

	// Output masks: eroded_mask / sediment_mask are the metre outputs over these depths, clamped to 0..1.
	// 0 = auto: 10% (eroded) and 1% (sediment) of the reference relief.
	float eroded_mask_depth = 0.0f;
	float sediment_mask_depth = 0.0f;

	// Stage 4: Post-Processing
	bool enable_post_smoothing = false;

	// Gate hooks, dictionary only. `reroute_lakes` off leaves pits as terminals; `stable_noise` off re-hashes
	// the routing noise every pass (the old behaviour, which never settles); `debug_network` returns the
	// final receivers and drainage areas.
	bool reroute_lakes = true;
	// The Stage 1 steady state (remapped to the reference relief) is held at or below the input, in metres,
	// before Stages 2-4. Free, it rebuilds untouched flat ground as a ramp up from the border outlets, which
	// on a brush is a step where the solve meets the ground around it. Off is the gate control only.
	bool lower_only = true;
	bool stable_noise = true;
	bool debug_network = false;
	// Gate hooks: `grid_solve` runs Stage 1 on the 8-connected grid (the S1 solver, the orientation control);
	// `reconstruct_only` samples the input onto the mesh and reconstructs it with no erosion.
	bool grid_solve = false;
	bool reconstruct_only = false;
	// Gate hook: return the grid (metres) entering and leaving Stage 3.
	bool debug_stages = false;
	// Gate hook: skip Stage 1, so Stages 2-4 run on the reconstructed input itself.
	bool skip_stage1 = false;

	static HydraulicSaleveParams from_dict(const Dictionary &p_dict);
};

struct HydraulicSaleveResult {
	bool ok = false;
	PackedFloat32Array height;
	PackedFloat32Array eroded_rock;
	PackedFloat32Array sediment;
	PackedFloat32Array eroded_mask; // 0..1, what the node's eroded_rock port carries
	PackedFloat32Array sediment_mask; // 0..1, what the node's sediment port carries
	int iterations = 0; // Stage 1 passes actually run
	PackedInt32Array receivers; // debug_network only
	PackedFloat32Array drainage_area; // debug_network only, in (cell metres / reference relief)^2
	float cell_area = 0.0f; // same unit as drainage_area
	int vertex_count = 0;
	PackedVector2Array vertices; // debug_network only, world metres
	PackedFloat32Array pre_stream; // debug_stages only, metres
	PackedFloat32Array post_stream; // debug_stages only, metres
	PackedFloat32Array deposition; // debug_stages only, Stage 2 raise in metres (before the composite)

	Dictionary to_dict() const;
};

HydraulicSaleveResult hydraulic_saleve_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const HydraulicSaleveParams &p_params);

} // namespace godot
