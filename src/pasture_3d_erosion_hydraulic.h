// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native Hydraulic Erosion solver (PASTURE3D_SOLVER_NATIVE_ACCELERATION_SPEC.md §4 Phase 1).
// Simulates continuous rainfall, downhill water routing, slope-limited sediment capacity, erosion pickup,
// sediment transport, deposition, and evaporation over an elevation heightfield.

#ifndef PASTURE_3D_EROSION_HYDRAULIC_H
#define PASTURE_3D_EROSION_HYDRAULIC_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <vector>

namespace godot {

struct ErosionHydraulicParams {
	// DOUBLE, not float. The solver computes in double and rounds only where it writes a grid, so it can
	// match the GDScript oracle exactly -- but the oracle's parameters are Variant doubles, and storing
	// them as float here made every inexact one (0.05, 0.02, 0.4, 0.01) arrive ~1e-9 off. One iteration
	// still agreed bit-for-bit; by the second the water grid differed by a float32 ULP, and the
	// `sed_c < cap` branch turns a ULP into a whole erode-or-deposit decision. That amplified to 8e-4 m
	// by iteration 15 -- GraphHydraulicAccelerationGate [A2]. The graph path is unaffected: its params
	// come from a float32 program, and a float widened to double is the same number.
	int iterations = 25;
	double rain_rate = 0.05;
	double evaporation_rate = 0.02;
	double sediment_capacity = 8.0;
	double erosion_speed = 0.5;
	double deposition_speed = 0.4;
	double min_slope = 0.01;
	// WALLS (default): the grid edge and no-data cells are walls, so water and sediment pool along them.
	// OUTLETS: each is a virtual neighbour whose surface is a fixed base level, `outlet_level` metres below
	// the sending cell's INPUT ground; whatever is routed there leaves the domain. The base level is the
	// input's, not the current ground's: an outlet that sank with the rim cut an ever-deeper trench (12 m
	// in 20 passes), because the rim could never erode down to it.
	enum { EDGE_WALLS = 0, EDGE_OUTLETS = 1 };
	int edge_mode = EDGE_WALLS;
	double outlet_level = 0.0;
	// MUSGRAVE (default): the per-pass routing model above, in grid steps. PIPE: Mei et al. 2007's
	// virtual-pipe shallow water, in metres and seconds, so it holds across resolutions. Under PIPE,
	// erosion_speed and deposition_speed are per second, sediment_capacity scales tilt x speed x depth,
	// and each iteration simulates `time_step` seconds, substepped for stability.
	enum { MODEL_MUSGRAVE = 0, MODEL_PIPE = 1 };
	int model = MODEL_MUSGRAVE;
	double time_step = 0.5;
	// Lay whatever sediment is still suspended when the solve ends onto the ground, instead of deleting it.
	// Off by default: the original solver dropped it, and settling it raises channel floors and basins.
	bool settle_at_end = false;

	static ErosionHydraulicParams from_dict(const Dictionary &p_dict);
};

struct ErosionHydraulicResult {
	bool ok = false;
	PackedFloat32Array height;
	// Net against the input, in metres, describing the FINAL surface: max(0, input - height) and
	// max(0, height - input). The old `sediment` was the suspended load, normalised to its own max.
	PackedFloat32Array eroded;
	PackedFloat32Array deposited;
	// MUSGRAVE: the contributing area draining through the cell, in m^2. PIPE: the mean discharge over the
	// simulated time, in m^3/s. Neither is normalised -- put a Float to Mask after it for a mask.
	PackedFloat32Array flow;

	Dictionary to_dict() const;
};

// Turns a finished solve's raw state into the output channels: settles the suspended load if asked, takes
// the net change against the input, and scales the flow accumulator into its physical unit. The GPU route
// calls this on its readback, so both routes derive their channels the same way.
ErosionHydraulicResult erosion_hydraulic_finish(const PackedFloat32Array &p_input,
		PackedFloat32Array &r_height, const PackedFloat32Array &p_sediment, const PackedFloat32Array &p_flow_accum,
		int p_gw, int p_gh, const Rect2 &p_rect, const ErosionHydraulicParams &p_params);

// C++ native grid hydraulic erosion solver: MUSGRAVE 4-neighbour sharing, or the PIPE shallow-water model.
// Matches the GDScript Tier 1 oracle bit-for-bit (<= 2e-6 m).
ErosionHydraulicResult erosion_hydraulic_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const ErosionHydraulicParams &p_params);

} // namespace godot

#endif // PASTURE_3D_EROSION_HYDRAULIC_H
