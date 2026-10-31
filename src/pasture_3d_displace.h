// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Displace — move an incoming surface sideways by two offset fields, in metres.
//
// The node Warp never was. Warp distorts only its OWN noise sample and adds the result to its input, so it
// cannot bend an existing hill: the input is read at the cell it already sits in. This reads the input at a
// displaced point instead, which is Hesiod's Warp (input, dx, dy), World Machine's Displacement and
// Houdini's HeightField Distort. Wire two noise fields into dx and dy to push a smooth hill's contours into
// lobes before eroding it.

#ifndef PASTURE_3D_DISPLACE_H
#define PASTURE_3D_DISPLACE_H

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// out(x) = surface(x + scale * (dx(x), dy(x)) * w(x)), where dx / dy are read as METRES on world X / Z and
// w = amount * clamp(mask, 0, 1). A resample is a backward map, so the surface's features move by the
// NEGATIVE of the offset — the same convention as Hesiod's Warp. Bilinear, CLAMP edges, NaN taps dropped:
// the sampler Transform and Warp Downslope already share.
//
// Any of p_dx, p_dy, p_mask may be empty: an empty offset is zero and an empty mask is fully on. A NaN
// offset or mask cell reads as no displacement.
PackedFloat32Array displace_solve(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_dx,
		const PackedFloat32Array &p_dy, const PackedFloat32Array &p_mask, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_scale, double p_amount);

} // namespace godot

#endif // PASTURE_3D_DISPLACE_H
