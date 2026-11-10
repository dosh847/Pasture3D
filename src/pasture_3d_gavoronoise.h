// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Gavoronoise — eroded-terrain noise: a Gabor-wave base, with gullies cut down its slopes.
// PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §7.2.
//
// PROVENANCE. The erosion stage follows Clay John's "Eroded Terrain Noise" (shadertoy MtGcWh) and the base
// follows Inigo Quilez's Gabor-wave noise (shadertoy clGyWm). Both are MIT; their notices are below. No
// GPLv3 code is used (spec §2). The hash, the metric frame and the base-input form are this project's.
//
//   Copyright 2020 Clay John
//   Copyright (c) 2023 Inigo Quilez
//
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
//   associated documentation files (the "Software"), to deal in the Software without restriction,
//   including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
//   and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
//   subject to the following conditions: The above copyright notice and this permission notice shall be
//   included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS",
//   WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS
//   OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
//   CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//   OTHER DEALINGS IN THE SOFTWARE.
//
// WHY IT WAS REWRITTEN. The first version was a Voronoi distance field (1 - F1) with derivative feedback.
// 1 - F1 is a cone on every feature point with a crease on every cell wall, so it drew faceted shards, not
// mountains, and its "ridges" were Voronoi edges with no relation to any slope. Erosion noise works the
// other way round: it starts from a smooth landform and cuts gullies that run DOWN that landform's slope.
//
// THE ALGORITHM IS DEFINED HERE, ONCE. Its three implementations must agree within their float widths:
// this file, the GAVORONOISE / GAVORONOISE_BASE shader modes in pasture_3d_graph_gpu.cpp, and the GDScript
// oracle in pasture3d_graph_node_dev_gavoronoise.gd. Positions are p = world_metres * frequency.
//
//   hash        hash_cell(cx, cz, seed, salt): uint32 multiply-xor-shift, 24 bits into [0,1). Integer, so
//               GLSL, C++ and GDScript agree exactly; a sin/fract hash does not.
//   gabor(p, k) For the 5x5 lattice cells c around floor(p): a point at c + (rnd1, rnd2), r = p - point,
//               a wave vector normalize(k + spread * (2 * (rnd3, rnd4) - 1)), weight exp(-4 |r|^2).
//               Returns sum(w cos(2 pi r.k')) / sum(w), in about [-1, 1]. k is the unit vector ACROSS the
//               strike, so crests run along `angle_deg`.
//   base(p)     8 octaves: v = gabor(p * nf, k) with seed + 7919 o; n += v * na; na *= min(v + 1, 2) / 2;
//               na *= 0.5; nf *= 2; starting na = 0.6, nf = 1. (Peaks rough, valleys smooth.)
//   eroder(p,d) For the 5x5 cells c around floor(p): a point at c + 0.5 * (rnd5, rnd6), r = p - point,
//               weight exp(-2 |r|^2), phase 2 pi r.d. Returns (sum(w cos), sum(-w sin d)) / sum(w): a value
//               and its slope. d is NOT normalised: steeper ground makes tighter gullies.
//   erosion     h = (0, 0, 0); a = 0.6 * smoothstep(z_cut_min, z_cut_max, base * 0.5 + 0.5); f = 1;
//               per octave o: e = eroder(p * erosion_frequency * f, d + branch * (h.dz, -h.dx)) with
//               seed 0x9e3779b9 + seed + 7919 o; h += a * (e.v, f e.dx, f e.dz); a *= 0.4; f *= 2.
//               The fed-back slope turns each octave's gullies off the last one's, which is the
//               branching; branch = 0 leaves every octave running straight down d.
//   direction   d = (dbase/dz, -dbase/dx) * slope_strength — along the contour, so the waves' crests
//               run DOWNHILL. GENERATOR: dbase by central difference at eps 0.1 in p units. BASE INPUT:
//               the metric gradient of the input (box-blurred over base_smoothing metres) times
//               2 / (amplitude * frequency), i.e. the input taken as base = 2 z / amplitude - 1.
//   output      GENERATOR: amplitude * (0.5 * (base + erosion_strength * h.v) + 0.5) metres.
//               BASE INPUT: z + erosion_strength * h.v * amplitude / 2 metres. NaN input stays NaN.

#ifndef PASTURE_3D_GAVORONOISE_H
#define PASTURE_3D_GAVORONOISE_H

#include <cmath>

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

struct GavoronoiseParams {
	double amplitude = 60.0; // metres: the generator's height, and the height scale a base input is read at
	double frequency = 0.002; // cycles per metre of the base
	int octaves = 8; // erosion octaves (the base always has 8)
	int seed = 0;
	double angle_deg = 0.0; // the base's strike
	double angle_spread = 1.0;
	double slope_strength = 1.0;
	double branch_strength = 2.0;
	double z_cut_min = 0.2; // erosion fades in between these normalised heights
	double z_cut_max = 1.0;
	double erosion_strength = 0.1;
	double erosion_frequency = 4.0; // erosion cells per base cell
	// The height range the landform is read at. -INF is "from amplitude" (min 0, max min + amplitude); +INF or
	// NaN is "measure the base's finite cells", falling back to the -INF rule when there is no base.
	double height_min = -INFINITY;
	double height_max = -INFINITY;
	// 0 is off, and the result is bit-identical to a node without it. Warps the pattern by this many base
	// cells of low-frequency noise and swings the gully depth by the same noise.
	double variation = 0.0;
};

// The generator form. Returns a grid of metres.
PackedFloat32Array gavoronoise_grid(int p_gw, int p_gh, const Rect2 &p_rect, const GavoronoiseParams &p);

// The base-input form: erode p_base (metres) along its own slope. p_base_smoothing_m box-blurs the surface
// the slope is read from; the height itself is not blurred.
PackedFloat32Array gavoronoise_base_grid(int p_gw, int p_gh, const Rect2 &p_rect, const GavoronoiseParams &p,
		const PackedFloat32Array &p_base, double p_base_smoothing_m);

} // namespace godot

#endif // PASTURE_3D_GAVORONOISE_H
