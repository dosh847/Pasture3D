// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Islet Scatter — small islands and sea stacks placed offshore of a coast.
//
// Placement is a jittered lattice in WORLD metres (`spacing`), hashed with the shared wang_hash, so islets do
// not move with resolution. A lattice candidate is kept when its centre lies on water, its distance to land
// (the shared JFA distance transform, metres) is in [min_offshore, max_offshore], and its hash draw is below
// `density`. A kept candidate becomes a SEA STACK with probability stack_fraction * exposure(centre),
// otherwise an ISLET.
//
// Shapes, with t = distance from the centre / radius(angle), radius(angle) roughened by three hashed
// harmonics scaled by `roughness`:
//   islet: z = sea - base_depth + (H + base_depth) * (1 - t^2)^0.75           (a dome)
//   stack: z = sea - base_depth + (H + base_depth) * smoothstep over t in [1, 0.75]  (flat top, steep sides),
//          radius 0.4x and height 1.5x of the islet draw.
// height' = max(height, z): islets only raise. Centres off the grid are not placed (the distance to land is
// unknown there), so a candidate near a region edge appears in the region that holds its centre only.
// A shaping tool, not a geological model.

#ifndef PASTURE_3D_ISLET_SCATTER_H
#define PASTURE_3D_ISLET_SCATTER_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// The sixteen-slot param block, in this order on both routes.
struct IsletScatterParams {
	double sea_level = 0.0;
	int seed = 0;
	double spacing = 150.0; // lattice cell, metres
	double density = 0.3; // 0..1 chance a candidate is kept
	double min_offshore = 30.0; // metres from land
	double max_offshore = 400.0;
	double radius_min = 15.0; // metres
	double radius_max = 60.0;
	double height_min = 5.0; // metres above sea level
	double height_max = 30.0;
	double base_depth = 10.0; // metres below sea level where the flank meets the floor
	double roughness = 0.3; // 0..1 outline irregularity
	double stack_fraction = 0.5; // 0..1, times exposure
};

IsletScatterParams islet_scatter_params_from(const float *p_params, int p_count);

// Returns {height, islets (1 where an islet stands above sea), stacks (1 where a stack does)}, each gw*gh.
// p_exposure may be empty (reads as 1). NaN cells pass through.
Dictionary islet_scatter_grid(const PackedFloat32Array &p_height, const PackedFloat32Array &p_exposure, int p_gw,
		int p_gh, const Rect2 &p_rect, const IsletScatterParams &p_prm);

} // namespace godot

#endif // PASTURE_3D_ISLET_SCATTER_H
