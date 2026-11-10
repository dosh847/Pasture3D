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
	float drainage_exponent = 0.2f;
	// Drainage area (m^2) at which Stage 1 starts to cut: below it a vertex keeps the input's slope. Smaller
	// means more, finer valleys. 0 = (relief / 8)^2, at least two control points' worth. It is a property of the
	// terrain: tied to the point count, more points meant deeper erosion everywhere (mean cut 1.7 m at 4000 points,
	// 15.6 m at 50000, on the same ground).
	float channel_area = 0.0f;
	float drainage_noise = 0.15f;
	float shape_preservation = 1.5f;
	// The height (metres) Shape Preservation measures high ground against, and the scale drainage lengths are
	// taken in, so the network is a property of the TERRAIN and not of the grid it happens to be solved on. It
	// does not scale the output. 0 = take it from the
	// input's own relief (zmax - zmin), which is convenient but moves whenever the solved extent changes
	// — most visibly under a brush's Modifier Margin, where the band brings surrounding ground into range.
	// Pin it to hold a shape steady across margins, resizes and re-bakes.
	float reference_relief = 0.0f;
	float bank_smoothing = 0.0f;
	// How steep Stage 1's ground may stand (dimensionless, m/m), unless the input already is: `max_slope_center`
	// at the domain centre falling to `max_slope_border` at a distance of the smaller domain side, along
	// 1 - r^2(3 - 2r). A valley's walls climb at this slope, and saleve_limit_edges holds every mesh edge to it.
	float max_slope_center = 1.5f;
	float max_slope_border = 1.5f;
	int seed = 0;
	PackedFloat32Array mask;
	PackedFloat32Array dx;
	PackedFloat32Array dy;

	// Coarse irregular solve (S2). Stage 1 runs on jittered control points triangulated by Delaunay, then is
	// reconstructed onto the grid. `point_spacing` (metres) wins when > 0 and pins the point lattice to the
	// world, so a margin adds points without moving any; 0 derives it from `control_points` over the rect.
	// `max_control_points` is the ceiling on the interior lattice whichever of the two asked for it: spacing
	// past it widens to fit, because a spacing is a count over the area and the area can be anything. Past
	// the cap the lattice stops being pinned, so a margin moves it. Only gates set this.
	int control_points = 15000;
	float point_spacing = 0.0f;
	int max_control_points = 100000;
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
	float stream_strength = 0.02f;
	float stream_exp = 0.8f;

	// Rim cap width, metres from the grid edge (0 = auto: 10% of the shorter side). Inside it the result is
	// eased down to at most the input height, so the solve meets the surrounding ground; beyond it the solve
	// is free, texture included.
	float rim_width = 0.0f;
	// Stage 1 outlets on the LOW GROUND, not only the grid border: every vertex within this fraction of the
	// grid's relief above its minimum drains out. With border-only outlets the steady state is built up from
	// however far away the border is, so a wider Modifier Margin lifted the whole brush (4.4 m at 16 m of
	// margin, 12 m at 60 m); with the plain as the outlet the level is set where the brush meets the ground.
	// 0 = border only (the pre-2026-09-19 behaviour, the gate control).
	float outlet_level = 0.1f;

	// How wide Stage 1's cut is smoothed on the grid, in metres, before it comes off the input. Walls climbing at a
	// fixed slope meet in a knife crest wherever two channels are close, and the triangles facet it further. The
	// cut is what is smoothed, so the input's own detail stays and ground outside a valley stays at the input.
	// 0 = auto, 1.5 x the control-point spacing. Negative is off, the gate control.
	float valley_smoothing = 0.0f;

	// Stage 4: Post-Processing
	bool enable_post_smoothing = false;

	// Gate hooks, dictionary only. `reroute_lakes` off leaves pits as terminals; `stable_noise` off re-hashes
	// the routing noise every pass (the old behaviour, which never settles); `debug_network` returns the
	// final receivers and drainage areas.
	bool reroute_lakes = true;
	// Stage 1 (in metres) is held at or below the input across the rim band (rim_width), before Stages 2-4.
	// Stage 1 rises only over a flooded pit, and on a brush a lake standing at the rim is a step where the
	// solve meets the ground around it. Off is the gate control only. `cap_everywhere`
	// is the old whole-grid cap, which flattened the texture on every rise; also a gate control only.
	bool lower_only = true;
	bool cap_everywhere = false;
	// Stage 2's flatness weight read off the unblurred fill: the pre-2026-09-19 behaviour that built ridges
	// down valley floors. Gate control only.
	bool flat_from_fill = false;
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
	// Gate hook: off leaves the mesh's non-receiver edges unbounded, the behaviour that stood fins on them.
	bool limit_edges = true;

	static HydraulicSaleveParams from_dict(const Dictionary &p_dict);
};

struct HydraulicSaleveResult {
	bool ok = false;
	PackedFloat32Array height;
	PackedFloat32Array eroded_rock;
	PackedFloat32Array sediment;
	int iterations = 0; // Stage 1 passes actually run
	PackedInt32Array receivers; // debug_network only
	PackedFloat32Array drainage_area; // debug_network only, in (cell metres / reference relief)^2
	float cell_area = 0.0f; // same unit as drainage_area
	int vertex_count = 0;
	PackedVector2Array vertices; // debug_network only, world metres
	PackedFloat32Array vertex_height; // debug_network only, metres: the Stage 1 surface before reconstruction
	PackedInt32Array vertex_neighbors; // debug_network only: pairs of vertex indices, one per mesh edge
	PackedFloat32Array pre_stream; // debug_stages only, metres
	PackedFloat32Array post_stream; // debug_stages only, metres
	PackedFloat32Array deposition; // debug_stages only, Stage 2 raise in metres (before the composite)

	Dictionary to_dict() const;
};

HydraulicSaleveResult hydraulic_saleve_solve(const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const HydraulicSaleveParams &p_params);

} // namespace godot
