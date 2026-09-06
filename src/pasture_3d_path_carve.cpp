// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_path_carve.h"

#include "pasture_3d_raster_util.h"
#include "pasture_3d_thread_pool.h"

#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

using namespace godot;

namespace {

// Bilinear sample of the surface at a world XZ, on the same CELL-CENTRE convention every other grid op
// uses. Out of the grid, or over NaN, answers NaN — the caller decides what "no ground here" means, and
// for this kernel it means "fall back to the cell's own surface".
double sample_surface(const float *p_surf, int p_gw, int p_gh, const Rect2 &p_rect, double p_x,
		double p_z) {
	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	if (dx <= 0.0 || dz <= 0.0) {
		return std::numeric_limits<double>::quiet_NaN();
	}
	// Cell centres sit half a cell in from the rect corner, so the continuous coordinate of a centre is
	// its index — which is what makes the floor/frac below the plain bilinear rather than an offset one.
	const double fx = ((p_x - (double)p_rect.position.x) / dx) - 0.5;
	const double fz = ((p_z - (double)p_rect.position.y) / dz) - 0.5;
	const int x0 = (int)std::floor(fx);
	const int z0 = (int)std::floor(fz);
	const double tx = fx - (double)x0;
	const double tz = fz - (double)z0;
	// CLAMPED to the edge rather than refused. A path vertex a little outside the evaluated rect is
	// completely normal — the rect is a brush's extent and the spline is longer than it — and returning
	// NaN there would make the ground reference jump at the boundary, which shows up as a step in the
	// crest exactly where the tile ends.
	auto at = [&](int p_ix, int p_iz) -> double {
		const int cx = std::clamp(p_ix, 0, p_gw - 1);
		const int cz = std::clamp(p_iz, 0, p_gh - 1);
		return (double)p_surf[(size_t)cz * (size_t)p_gw + (size_t)cx];
	};
	const double v00 = at(x0, z0), v10 = at(x0 + 1, z0);
	const double v01 = at(x0, z0 + 1), v11 = at(x0 + 1, z0 + 1);
	// NaN-aware: a hole in the terrain must not poison the whole bilinear cell into NaN, because the
	// vertex reference is what keeps the crest smooth and one missing corner would notch it. Weight only
	// the finite corners; all four missing is a genuine "no ground here".
	double sum = 0.0, wt = 0.0;
	auto add = [&](double p_v, double p_w) {
		if (std::isfinite(p_v)) {
			sum += p_v * p_w;
			wt += p_w;
		}
	};
	add(v00, (1.0 - tx) * (1.0 - tz));
	add(v10, tx * (1.0 - tz));
	add(v01, (1.0 - tx) * tz);
	add(v11, tx * tz);
	return wt > 0.0 ? sum / wt : std::numeric_limits<double>::quiet_NaN();
}

} // namespace

Pasture3DPathCarveParams godot::path_carve_params_from(const float *p_params, int p_count) {
	Pasture3DPathCarveParams cp;
	if (p_params == nullptr) {
		return cp;
	}
	// Every slot falls back to the struct's own default rather than to 0. A program compiled before a
	// parameter existed is short, not wrong, and reading a missing `slope_angle` as 0 degrees would give
	// an infinite flank reach — where reading it as the default 30 gives the shape the node advertises.
	auto at = [&](int p_i, double p_default) -> double {
		return p_i < p_count ? (double)p_params[p_i] : p_default;
	};
	cp.cross_section = (int)at(0, (double)cp.cross_section);
	cp.offset = at(1, cp.offset);
	cp.flat_width = at(2, cp.flat_width);
	cp.flank_mode = (int)at(3, (double)cp.flank_mode);
	cp.slope_angle = at(4, cp.slope_angle);
	cp.width_source = (int)at(5, (double)cp.width_source);
	cp.width_scale = at(6, cp.width_scale);
	cp.width = at(7, cp.width);
	cp.follow_path_height = at(8, cp.follow_path_height ? 1.0 : 0.0) > 0.5;
	cp.blend = (int)at(9, (double)cp.blend);
	cp.falloff = at(10, cp.falloff);
	return cp;
}

Dictionary godot::path_carve_grid_geom(const Pasture3DPathGeom &p_geom,
		const PackedFloat32Array &p_surface, int p_gw, int p_gh, const Rect2 &p_rect,
		const PackedFloat32Array &p_profile_lut, const Pasture3DPathCarveParams &p_params) {
	Dictionary out;
	const int n = p_gw * p_gh;
	if (p_gw <= 0 || p_gh <= 0 || p_surface.size() != n) {
		out["ok"] = false;
		return out;
	}
	PackedFloat32Array height, bed, flank, cut, fill;
	height.resize(n);
	bed.resize(n);
	flank.resize(n);
	cut.resize(n);
	fill.resize(n);

	const float *surf = p_surface.ptr();
	float *h_w = height.ptrw();
	float *b_w = bed.ptrw();
	float *k_w = flank.ptrw();
	float *c_w = cut.ptrw();
	float *f_w = fill.ptrw();

	// PASS THE SURFACE THROUGH when there is nothing to carve. Not zeros, and not a per-cell branch: an
	// unresolved Spline Source is a normal state that a graph mid-edit passes through constantly, and a
	// carve that answered zeros while a spline was being renamed would flatten the terrain to sea level.
	if (p_geom.is_empty()) {
		std::copy_n(surf, n, h_w);
		std::fill_n(b_w, n, 0.f);
		std::fill_n(k_w, n, 0.f);
		std::fill_n(c_w, n, 0.f);
		std::fill_n(f_w, n, 0.f);
		out["ok"] = true;
		out["height"] = height;
		out["bed"] = bed;
		out["flank"] = flank;
		out["cut"] = cut;
		out["fill"] = fill;
		return out;
	}

	// ---- the ground reference, per PATH VERTEX ----
	//
	// O(vertices), not O(cells), and that is the point as much as the smoothness is: the crest's shape is
	// decided by a few dozen samples of the terrain rather than by every cell the flank crosses.
	const int nv = (int)p_geom.px.size();
	std::vector<float> gv((size_t)nv, 0.f);
	for (int v = 0; v < nv; v++) {
		gv[(size_t)v] = (float)sample_surface(surf, p_gw, p_gh, p_rect, (double)p_geom.px[(size_t)v],
				(double)p_geom.pz[(size_t)v]);
	}

	const double flat_hw = std::max(p_params.flat_width, 0.0);
	// tan of the flank angle, floored so a zero angle cannot divide by zero into an infinite reach.
	const double slope_tan = std::max(std::tan(std::clamp(p_params.slope_angle, 0.5, 89.5) * Math_PI / 180.0),
			1.0e-4);
	const double falloff = std::max(p_params.falloff, 0.0);
	const double falloff_d = std::max(falloff, 1.0e-3);
	// The profile's value AT THE FOOT, which is what the feather beyond the foot decays from. Read once:
	// a curve that does not actually reach 0 there would otherwise step to 0 at the foot, and the step
	// would be a hard line in the terrain exactly where the carve was supposed to stop being visible.
	const double edge_val = (double)pasture3d_raster_ramp(p_profile_lut, 1.0f);
	// CREST raises, BED lowers. The one place the enum becomes a number.
	const double signed_offset = p_params.cross_section == PATH_CARVE_BED ? -p_params.offset
																		  : p_params.offset;
	const bool follow = p_params.follow_path_height;
	const bool from_path = p_params.width_source == PATH_CARVE_WIDTH_PATH;
	const bool by_angle = p_params.flank_mode == PATH_CARVE_SLOPE_ANGLE;

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double min_x = (double)p_rect.position.x + 0.5 * dx;
	const double min_z = (double)p_rect.position.y + 0.5 * dz;

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		std::vector<int> scratch;
		scratch.reserve(32);
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			const double wz = min_z + (double)iz * dz;
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = row + ix;
				const double ground = (double)surf[i];
				h_w[i] = surf[i];
				b_w[i] = 0.f;
				k_w[i] = 0.f;
				c_w[i] = 0.f;
				f_w[i] = 0.f;
				// NaN is "no data" in a HEIGHT grid, and a carve is not entitled to invent ground.
				if (!std::isfinite(ground)) {
					continue;
				}
				const Pasture3DPathHit hit = p_geom.nearest(min_x + (double)ix * dx, wz, scratch);
				const double lat = hit.distance;

				// The flank's lateral reach, then the total half-span including the flat middle.
				const double reach = from_path
						? std::max(p_geom.half_width_at(hit.s) * p_params.width_scale, 0.0)
						: std::max(p_params.width, 0.0);
				const double span = flat_hw + reach;
				if (lat > span + falloff) {
					continue; // outside even the feather: the surface stands as it is
				}

				// Reference 1: the ground UNDER THE PATH, interpolated from the vertex samples. Falls back
				// to this cell's own ground where the path crossed a hole — which keeps a carve over a
				// gap continuous instead of NaN-poisoned.
				const double gs = p_geom.lerp_vertex(gv, hit.s);
				const double ground_ref = std::isfinite(gs) ? gs : ground;

				// Reference 2: the crest or floor. `follow_path_height` reads the path's drawn Y; a path
				// carrying no heights answers NaN, and falling back to the ground reference is what makes
				// an unelevated spline behave as "offset from the terrain" rather than as a carve to sea
				// level. The node warns rather than letting this be silent.
				double top = ground_ref;
				if (follow) {
					const double py = p_geom.height_at(hit.s);
					if (std::isfinite(py)) {
						top = py;
					}
				}
				top += signed_offset;
				const double diff = top - ground_ref;

				// SLOPE_ANGLE: descend at the angle until the flank meets the ground, capped by the reach.
				// A tall carve over a narrow span stays at the span; a shallow one stops early rather than
				// spreading a 2 cm ridge over 25 metres.
				double w_eff = span;
				if (by_angle) {
					w_eff = std::clamp(flat_hw + std::fabs(diff) / slope_tan, flat_hw, span);
				}
				if (lat > w_eff + falloff) {
					continue;
				}

				double p;
				if (lat <= flat_hw) {
					p = 1.0; // the flat top or floor
				} else if (lat <= w_eff) {
					const double u = (lat - flat_hw) / std::max(w_eff - flat_hw, 1.0e-3);
					p = (double)pasture3d_raster_ramp(p_profile_lut, (float)u);
				} else {
					p = edge_val * (1.0 - std::clamp((lat - w_eff) / falloff_d, 0.0, 1.0));
				}
				if (p <= 0.0) {
					continue;
				}

				// The drape. `ground`, not `ground_ref`: the flank meets the terrain WHERE IT ACTUALLY IS,
				// while only the shape — `diff` and `w_eff` — is anchored to the vertex reference. That
				// split is the whole two-reference rule in one line.
				const double carved = ground + diff * p;
				double result = carved;
				if (p_params.blend == PATH_CARVE_MAX) {
					result = std::max(carved, ground);
				} else if (p_params.blend == PATH_CARVE_MIN) {
					result = std::min(carved, ground);
				}

				h_w[i] = (float)result;
				if (lat <= flat_hw) {
					b_w[i] = 1.f;
				} else if (lat <= w_eff) {
					k_w[i] = (float)p;
				}
				// Split by the sign of the ACTUAL change, not by `cross_section`: a crest laid over a
				// hilltop fills at the middle and cuts at the flanks, and a mask that assumed otherwise
				// would hand erosion the wrong half of it.
				const double delta = result - ground;
				if (delta < 0.0) {
					c_w[i] = (float)p;
				} else if (delta > 0.0) {
					f_w[i] = (float)p;
				}
			}
		}
	});

	out["ok"] = true;
	out["height"] = height;
	out["bed"] = bed;
	out["flank"] = flank;
	out["cut"] = cut;
	out["fill"] = fill;
	return out;
}

Dictionary godot::path_carve_grid(const PackedVector2Array &p_points, const PackedFloat32Array &p_widths,
		const PackedFloat32Array &p_heights, bool p_closed, const PackedFloat32Array &p_surface, int p_gw,
		int p_gh, const Rect2 &p_rect, const PackedFloat32Array &p_profile_lut,
		const Pasture3DPathCarveParams &p_params) {
	Pasture3DPathGeom geom;
	// Closed EXACTLY as the geometry table and the mask kernel close it. Two closings that differed by
	// one segment would put a seam across the mouth of every closed carve.
	geom.closed = p_closed && p_points.size() >= 3;
	geom.build(path_close_ring(p_points, p_closed), p_widths, p_heights);
	return path_carve_grid_geom(geom, p_surface, p_gw, p_gh, p_rect, p_profile_lut, p_params);
}
