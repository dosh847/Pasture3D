// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native Particle Hydraulic Erosion solver (PASTURE3D_EROSION_NODES_EXPANSION_SPEC.md §3.1 Phase 1).
// Simulates Lagrangian water droplets with inertia, momentum, capacity, erosion pickup, and deposition.

#ifndef PASTURE_3D_HYDRAULIC_PARTICLE_H
#define PASTURE_3D_HYDRAULIC_PARTICLE_H

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <vector>

namespace godot {

struct HydraulicParticleParams {
	// DOUBLE, not float, for the reason ErosionHydraulicParams gives: the oracle's parameters are Variant
	// doubles, and storing 0.05 or 0.3 as float made them arrive ~1e-9 off, which the droplets amplified
	// into a metre by the default lifetime (GraphHydraulicParticleGate [A3]). The graph path's float32
	// program params widen to the same number, so it is unaffected.
	int droplet_count = 25000;
	int max_lifetime = 30;
	double inertia = 0.05;
	double sediment_capacity = 4.0;
	double erosion_speed = 0.3;
	double deposition_speed = 0.3;
	double evaporation_rate = 0.01;
	double min_slope = 0.01;
	double gravity = 4.0;
	double bedrock_gap = 2.0;
	double ridge_forcing = 0.0;
	int64_t seed = 1337;
	// CELLS: every length is a grid cell (the original solver). METRIC: world metres, resolution-invariant.
	enum { UNITS_CELLS = 0, UNITS_METRIC = 1 };
	int units = UNITS_CELLS;
	// Erosion brush radius in metres (Beyer). 0 = the four bilinear corners. METRIC widens it to one step.
	double radius_m = 0.0;
	// METRIC only: the length of one droplet step, and droplets per 100 m^2 of the rect.
	double step_length_m = 1.0;
	double droplet_density = 40.0;
	// A droplet that dies (lifetime out, an edge ahead, a pit) still carrying sediment drops it where it
	// stands, so no mass leaves except by the mask. Off by default: the original solver discarded it.
	bool deposit_at_death = false;
	PackedFloat32Array mask;

	static HydraulicParticleParams from_dict(const Dictionary &p_dict);
};

struct HydraulicParticleResult {
	bool ok = false;
	PackedFloat32Array height;
	// Net against the input, in metres: max(0, input - height) and max(0, height - input). What the final
	// surface shows, not what passed through (a deposit later eroded away is in neither).
	PackedFloat32Array eroded;
	PackedFloat32Array deposited;
	// Water-weighted droplet path length per unit area, per unit droplet density (droplets per m^2): metres.
	// Proportional to drainage, and the same at every resolution under METRIC.
	PackedFloat32Array flow;

	Dictionary to_dict() const;
};

// C++ native Lagrangian droplet solver.
// Matches the GDScript Tier 1 oracle bit-for-bit (<= 2e-6 m).
HydraulicParticleResult hydraulic_particle_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const HydraulicParticleParams &p_params);

} // namespace godot

#endif // PASTURE_3D_HYDRAULIC_PARTICLE_H
