// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Coast Profile kernel. See pasture_3d_coast_profile.h for the profile and why it is parametric.

#include "pasture_3d_coast_profile.h"
#include "pasture_3d_path_query.h"
#include "pasture_3d_thread_pool.h"

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>
#include <vector>

using namespace godot;

namespace {

inline double sat(double p_x) { return std::clamp(p_x, 0.0, 1.0); }

inline double ss(double p_x) {
	const double t = sat(p_x);
	return t * t * (3.0 - 2.0 * t);
}

// A width of 0 is a step, not a division by zero.
inline double ramp(double p_x, double p_w) { return p_w > 1e-6 ? ss(p_x / p_w) : (p_x >= 0.0 ? 1.0 : 0.0); }

// 1 over [p_a, p_b], fading to 0 over p_f outside it.
inline double band(double p_x, double p_a, double p_b, double p_f) {
	if (p_f <= 1e-6) return (p_x >= p_a && p_x <= p_b) ? 1.0 : 0.0;
	return sat((p_x - p_a) / p_f + 1.0) * sat((p_b - p_x) / p_f + 1.0);
}

} // namespace

CoastProfileParams godot::coast_profile_params_from(const float *p_params, int p_count) {
	CoastProfileParams r;
	auto at = [&](int i, double d) -> double { return (p_params && i < p_count) ? (double)p_params[i] : d; };
	r.shelf_depth = std::max(at(0, r.shelf_depth), 0.0);
	r.shelf_width = std::max(at(1, r.shelf_width), 0.0);
	r.floor_depth = std::max(at(2, r.floor_depth), 0.0);
	r.drop_width = std::max(at(3, r.drop_width), 0.0);
	r.beach_height = at(4, r.beach_height);
	r.beach_width = std::max(at(5, r.beach_width), 0.0);
	r.cliff_height = at(6, r.cliff_height);
	r.cliff_width = std::max(at(7, r.cliff_width), 0.0);
	r.inland_height = at(8, r.inland_height);
	r.inland_width = std::max(at(9, r.inland_width), 0.0);
	r.inland_curve = std::max(at(10, r.inland_curve), 0.01);
	r.sea_level = at(11, r.sea_level);
	r.mask_feather = std::max(at(12, r.mask_feather), 0.0);
	r.slope_width = std::max(at(13, r.slope_width), r.cliff_width);
	return r;
}

Dictionary godot::coast_profile_grid_geom(const Pasture3DPathGeom *p_geom, const PackedFloat32Array &p_cliff,
		int p_gw, int p_gh, const Rect2 &p_rect, const CoastProfileParams &p_prm) {
	Dictionary out;
	if (p_gw <= 0 || p_gh <= 0) {
		return out;
	}
	const int n = p_gw * p_gh;
	PackedFloat32Array h, sd, shelf, beach, cliff;
	h.resize(n);
	sd.resize(n);
	shelf.resize(n);
	beach.resize(n);
	cliff.resize(n);

	const CoastProfileParams P = p_prm;
	// The floor sits BELOW the shelf whatever the user typed, so the drop never climbs back up.
	const double floor_depth = std::max(P.floor_depth, P.shelf_depth);
	const bool have_island = p_geom != nullptr && !p_geom->is_empty() && p_geom->closed;
	const bool have_cliff = p_cliff.size() == n;
	const float *cp = have_cliff ? p_cliff.ptr() : nullptr;

	const double dx = p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = p_rect.size.y / (double)std::max(p_gh, 1);
	const double min_x = p_rect.position.x + 0.5 * dx;
	const double min_z = p_rect.position.y + 0.5 * dz;
	float *wh = h.ptrw();
	float *wsd = sd.ptrw();
	float *wsh = shelf.ptrw();
	float *wb = beach.ptrw();
	float *wc = cliff.ptrw();

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		std::vector<int> scratch;
		scratch.reserve(32);
		for (int iz = z0; iz < z1; iz++) {
			const double wz = min_z + (double)iz * dz;
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = iz * p_gw + ix;
				const double wx = min_x + (double)ix * dx;
				double d = -10000.0;
				if (have_island) {
					const double dist = p_geom->nearest(wx, wz, scratch).distance;
					d = p_geom->inside(wx, wz) ? dist : -dist;
				}
				double c = 1.0;
				if (cp) {
					const float v = cp[i];
					c = std::isnan(v) ? 0.0 : sat((double)v);
				}
				const double bw = P.beach_width * (1.0 - c);
				// c sets the rise's steepness, not its height: written as a weighted sum so c = 1 is exactly
				// cliff_width and an unwired mask stays bit-identical to the old profile.
				const double wcl = P.cliff_width * c + P.slope_width * (1.0 - c);
				double z;
				if (d >= 0.0) {
					const double x = d - bw - wcl;
					const double inland = x <= 0.0 ? 0.0 : std::pow(ramp(x, P.inland_width), P.inland_curve);
					z = P.beach_height * ramp(d, bw) + P.cliff_height * ramp(d - bw, wcl)
							+ P.inland_height * inland;
				} else {
					const double e = -d;
					z = -P.shelf_depth * ramp(e, P.shelf_width)
							- (floor_depth - P.shelf_depth) * ramp(e - P.shelf_width, P.drop_width);
				}
				wh[i] = (float)(P.sea_level + z);
				wsd[i] = (float)d;
				const double f = P.mask_feather;
				wsh[i] = (float)(d < 0.0 ? band(-d, 0.0, P.shelf_width, f) : 0.0);
				wb[i] = (float)(band(d, 0.0, bw, f) * (1.0 - c));
				wc[i] = (float)(band(d, bw, bw + wcl, f) * c * (P.cliff_height > 0.0 ? 1.0 : 0.0));
			}
		}
	});

	out["height"] = h;
	out["signed_distance"] = sd;
	out["shelf"] = shelf;
	out["beach"] = beach;
	out["cliff"] = cliff;
	return out;
}
