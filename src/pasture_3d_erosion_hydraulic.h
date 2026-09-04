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

	static ErosionHydraulicParams from_dict(const Dictionary &p_dict);
};

struct ErosionHydraulicResult {
	bool ok = false;
	PackedFloat32Array height;
	PackedFloat32Array sediment;
	PackedFloat32Array flow;

	Dictionary to_dict() const;
};

// C++ native hydrodynamic shallow-water solver.
// Matches the GDScript Tier 1 oracle bit-for-bit (<= 2e-6 m).
ErosionHydraulicResult erosion_hydraulic_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const ErosionHydraulicParams &p_params);

} // namespace godot

#endif // PASTURE_3D_EROSION_HYDRAULIC_H
