// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// The relief FRACTAL material's kernel, lifted whole for the terrain graph's Fractal generator node.
//
// This is the same field Pasture3DReliefFractal emits — a WARP op followed by an FBM / RIDGED / BILLOW op
// — evaluated over a grid instead of through the relief op-program. It is written here rather than reached
// through relief_eval because a graph generator has no accumulator, no selector and no blend: everything
// the program wrapper exists for is absent, and running an op stream of length two per cell to get one
// noise read would cost the graph its whole reason for having a native tier.
//
// PARITY IS THE CONSTRAINT. Pasture3DGraphNodeFractal.eval_cell walks the GDScript relief statics and this
// must agree with it; GraphFractalNodeGate holds both to a relief material built from the same numbers.
// The noise construction below therefore mirrors Pasture3DReliefMaterial._configure_noise EXACTLY,
// including the two decorrelated warp fields and their +1013 seed offset.

#pragma once

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// Style ids — sync with Pasture3DReliefFractal.Style / Pasture3DGraphNodeFractal.Style.
enum FractalStyle {
	FRACTAL_STYLE_HILLS = 0, // fBm
	FRACTAL_STYLE_CRAGGY = 1, // ridged multifractal
	FRACTAL_STYLE_LUMPY = 2, // billow
};

PackedFloat32Array fractal_grid(int p_gw, int p_gh, const Rect2 &p_rect,
		int p_style, double p_amplitude, double p_feature_size, int p_octaves,
		double p_lacunarity, double p_gain, double p_sharpness, int p_seed,
		double p_warp_amount, double p_warp_size, int p_warp_octaves);

} // namespace godot
