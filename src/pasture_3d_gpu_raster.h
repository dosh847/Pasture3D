#ifndef PASTURE_3D_GPU_RASTER_H
#define PASTURE_3D_GPU_RASTER_H

// GPU analytic signed-distance rasteriser (PASTURE3D_BRUSH_GPU_RASTER_SPEC.md, Phase 1).
//
// Owns a *local* RenderingDevice and a single compute shader that computes, per output texel, the exact
// analytic signed distance to a closed world polygon (even-odd inside test + minimum distance to any
// edge) and atomic-maxes the interior distance into a 1-element buffer. This is a drop-in replacement for
// the CPU serial chamfer transform (`raster_sdf` in pasture_3d_brush_raster.cpp): it fills the same
// gw*gh `field` array (positive inside / negative outside, metres) and returns the same `max_inside`, so
// the caller's per-cell profile/base/noise/blend loop is byte-identical and the ONLY behavioural change is
// chamfer-approximate -> analytic-exact distance (the documented A/B delta, spec §7).
//
// Self-contained and side-effect-free: no engine reads, no layer writes. The caller decides (by box size
// threshold) whether to call this at all, and falls back to the C++ chamfer if `closed_loop_field` returns
// false (RD/driver/compile gap) — three-tier fallback GPU -> C++ -> GDScript (spec §4).

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include <vector>

using namespace godot; // Match the project convention (constants.h); Pasture3DData is global, not godot::.

class Pasture3DGPURaster {
public:
	Pasture3DGPURaster() {}
	~Pasture3DGPURaster();

	// True once the local RD + compute pipeline exist (lazily initialised). False => caller uses C++.
	bool available();

	// Compute the analytic signed-distance field of `p_poly` (closed, world XZ; .x=x, .y=z) over the
	// gw*gh grid anchored at (min_x,min_z) with spacing vs. On success fills r_field (size gw*gh,
	// row-major, positive inside) and r_max_inside (max interior distance) and returns true. Returns
	// false on any failure (caller must fall back to the CPU path); r_field/r_max_inside untouched then.
	bool closed_loop_field(const PackedVector2Array &p_poly, double p_min_x, double p_min_z, double p_vs,
			int p_gw, int p_gh, std::vector<float> &r_field, float &r_max_inside);

private:
	RenderingDevice *_rd = nullptr;
	RID _shader;
	RID _pipeline;
	bool _init_failed = false;

	bool _ensure_init();
};

#endif // PASTURE_3D_GPU_RASTER_H
