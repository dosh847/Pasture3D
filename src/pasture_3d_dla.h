// Diffusion-limited aggregation massif growth — the C++ port of Pasture3DReliefDLA.grow_into
// (project/addons/pasture_3d/connectors/pasture3d_relief_dla.gd).
//
// ---- A PORT, NOT A REIMPLEMENTATION ----
//
// The GDScript growth carries a history of six bugs that each produced a PLAUSIBLE mountain, so this does
// not re-derive anything: every function mirrors one of the script's, in the same order, drawing from the
// random stream in the same order. GraphDLANativeParityGate compares the two fields cell for cell.
//
// Two things make that comparison exact rather than approximate, and both are easy to lose:
//   * STORAGE WIDTH. GDScript computes in double but stores node positions, blur buffers and Vector2s as
//     float32. Every such store here is float32 too, and the arithmetic between stores is double.
//   * THE RANDOM STREAM. Godot's RandomNumberGenerator is PCG32 with its own float conversions and a
//     real_t (float32) randfn. DLAPcg reproduces it; dla_rng_probe exposes it for the gate to check against
//     the engine draw by draw, because a wrong conversion here moves every particle after the first.

#pragma once

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cstdint>

namespace godot {

struct DLAParams {
	int64_t seed = 0;
	int resolution = 256;
	int hierarchy_levels = 4;
	double detail_size = 0.12;
	double ridge_width = 0.18;
	double wander = 0.32;
	double profile_power = 1.0;
	double coverage = 0.95;
	bool ridge_seeding = false;
	double ridge_amount = 0.05;
	// The loop's half-extents in metres (Pasture3DReliefDLA._host_ex / _host_ez).
	double host_ex = 1.0;
	double host_ez = 1.0;
	// The captured seed surface (Pasture3DReliefDLA._seed). Empty = unseeded.
	PackedFloat32Array seed_surface;
	int seed_gw = 0;
	int seed_gh = 0;
	// The captured outline surface (Pasture3DReliefDLA._shape) — the same grid, read for its NaN boundary
	// rather than its ridges. Empty = no loop to follow, and the envelope falls back to the ellipse.
	PackedFloat32Array shape_surface;
	int shape_gw = 0;
	int shape_gh = 0;
	// [cx, cz, cos, sin, ex, ez, min_x, min_z, vs] — the loop frame, as the script's `frame` array.
	double frame[9] = { 0, 0, 1, 0, 0, 0, 0, 0, 0 };
	int frame_size = 0;
};

struct DLAResult {
	PackedFloat32Array field; // n x n, normalised [0,1]
	int n = 0;
	Vector2i dims; // the loop's crop of the square grid (Pasture3DReliefDLA._field_dims)
	// Walk batches that actually split across threads — for the thread-parity gate, which must be able to tell
	// a threaded walk from a batch too small to split.
	int64_t walk_dispatches = 0;
};

// Pasture3DReliefDLA.grow_into, returning what it writes into its state Dictionary (minus the key).
DLAResult dla_grow(const DLAParams &p_params);

// `p_count` rounds of [randi(), randf(), randfn(0, p_dev)] from a stream seeded like `rng.seed = p_seed`,
// flattened. For the gate only: the engine's RandomNumberGenerator must produce the same 3*count values.
PackedFloat64Array dla_rng_probe(int64_t p_seed, int p_count, double p_dev);

} // namespace godot
