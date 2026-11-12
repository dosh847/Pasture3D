// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Mask Feather — the soft edge Path Mask gives a PATH, for ANY mask.
//
// Path Mask feathers by DISTANCE: inside the shape is a flat 1 and the mask falls linearly to 0 over
// `feather` metres beyond the edge. This does the same for a grid mask: threshold it, take the SIGNED
// distance transform (§5.1, the shared JFA kernel — no second distance implementation), and window the
// distance from the edge. Not a blur: a blur pulls a thin mask's peak below 1 and moves a convex corner
// inward, where a distance feather keeps the shape's own strength and only adds the ramp.
//
// THE EDGE IS HALF A CELL OUT. The transform measures cell centre to cell centre, so the first cell outside
// a mask reads one whole cell from it. The true contour lies between them, and measuring from the centre
// would move the ramp's start by half a cell whenever the bake resolution changes. Both signs are pulled
// back by half a cell so the zero of the edge distance sits on the contour.
//
// Params (P[16]): 0 feather metres, 1 side (MaskFeatherSide), 2 falloff (MaskFeatherFalloff),
// 3 threshold, 4 invert (> 0.5).

#ifndef PASTURE_3D_MASK_FEATHER_H
#define PASTURE_3D_MASK_FEATHER_H

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// Sync with Pasture3DGraphNodeMaskFeather.FeatherSide.
enum MaskFeatherSide {
	MASK_FEATHER_OUTWARD = 0, // 1 inside, falls to 0 over `feather` beyond the edge — Path Mask's rule
	MASK_FEATHER_INWARD = 1, // 0 outside, rises to 1 over `feather` inside the edge — the shape never grows
	MASK_FEATHER_CENTRED = 2, // 0.5 on the edge, the ramp straddling it, `feather` wide in all
};

// Sync with Pasture3DGraphNodeMaskFeather.EdgeFalloff.
enum MaskFeatherFalloff {
	MASK_FEATHER_LINEAR = 0,
	MASK_FEATHER_SMOOTH = 1,
};

struct MaskFeatherParams {
	double feather = 2.0;
	int side = MASK_FEATHER_OUTWARD;
	int falloff = MASK_FEATHER_LINEAR;
	double threshold = 0.5;
	bool invert = false;
};

// Unpacks the sixteen-slot block. Shared by the binding and the graph op so the two cannot disagree.
MaskFeatherParams mask_feather_params_from(const float *p_P, int p_count);

// Returns p_gw * p_gh in [0, 1]; NaN cells stay NaN. Empty when the input is the wrong size.
PackedFloat32Array mask_feather_solve(const PackedFloat32Array &p_mask, int p_gw, int p_gh,
		const Rect2 &p_rect, const MaskFeatherParams &p_params);

} // namespace godot

#endif // PASTURE_3D_MASK_FEATHER_H
