// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Native PATH Operations (Reshape and Derive Families)
// Implements high-performance C++ algorithms for:
// - Derive Family (GRID -> PATH): PathDrape, PathWidthField, PathFromFlow
// - Reshape Family (PATH -> PATH): PathResample, PathSmooth, PathDecimate,
//                                 PathFractalize, PathMeanderize, PathWidth
// - Core Polyline Mechanics: arc lengths, segment projection, attribute lerp,
//                           grid bilinear sampling.

#include "pasture_3d_path_ops.h"

#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace godot {

// ---- Core Polyline & Field Geometry Helpers ---------------------------------

PackedFloat32Array path_arc_lengths(const PackedVector2Array &p_pts, bool p_closed) {
	int n = p_pts.size();
	int count = (p_closed && n >= 2) ? n + 1 : n;
	PackedFloat32Array cum;
	cum.resize(count);
	if (count == 0) {
		return cum;
	}
	float *cum_ptr = cum.ptrw();
	const Vector2 *pts = p_pts.ptr();
	cum_ptr[0] = 0.0f;
	for (int i = 1; i < n; ++i) {
		cum_ptr[i] = cum_ptr[i - 1] + (float)pts[i].distance_to(pts[i - 1]);
	}
	if (p_closed && n >= 2) {
		cum_ptr[n] = cum_ptr[n - 1] + (float)pts[0].distance_to(pts[n - 1]);
	}
	return cum;
}

double path_project_s(const PackedVector2Array &p_pts, const PackedFloat32Array &p_cum,
		const Vector2 &p_q, bool p_closed) {
	int n = p_pts.size();
	if (n < 2 || p_cum.size() < 2) {
		return 0.0;
	}
	double best = 1e30;
	double best_s = 0.0;
	int seg_count = (p_closed && n >= 2) ? n : (n - 1);
	const Vector2 *pts = p_pts.ptr();
	const float *cum = p_cum.ptr();

	for (int i = 0; i < seg_count; ++i) {
		Vector2 a = pts[i];
		Vector2 b = pts[(i + 1) % n];
		Vector2 ab = b - a;
		double len2 = ab.length_squared();
		double t = (len2 <= 0.0) ? 0.0 : Math::clamp(static_cast<double>((p_q - a).dot(ab) / len2), 0.0, 1.0);
		Vector2 proj = a + ab * (real_t)t;
		double d = p_q.distance_squared_to(proj);
		if (d < best) {
			best = d;
			double s0 = cum[i];
			double s1 = cum[i + 1];
			best_s = s0 + (s1 - s0) * t;
		}
	}
	return best_s;
}

float path_sample_along(const PackedFloat32Array &p_vals, const PackedFloat32Array &p_cum,
		double p_s, bool p_closed) {
	int n = p_vals.size();
	if (n == 0) {
		return NAN;
	}
	const float *vals = p_vals.ptr();
	const float *cum = p_cum.ptr();
	int cum_sz = p_cum.size();
	if (n == 1 || cum_sz < 2) {
		return vals[0];
	}
	float last = cum[cum_sz - 1];
	if (p_s <= 0.0 || last <= 0.0f) {
		return vals[0];
	}
	if (p_s >= last) {
		return p_closed ? vals[0] : vals[std::min(cum_sz - 1, n - 1)];
	}
	int i = 1;
	while (i < cum_sz - 1 && cum[i] < p_s) {
		i++;
	}
	float s0 = cum[i - 1];
	float s1 = cum[i];
	float t = (s1 <= s0) ? 0.0f : static_cast<float>((p_s - s0) / (s1 - s0));
	float v0 = vals[(i - 1) % n];
	float v1 = vals[i % n];
	return v0 + (v1 - v0) * t;
}

void path_carry_values(const PackedVector2Array &p_src_pts, const PackedFloat32Array &p_src_widths,
		const PackedFloat32Array &p_src_heights, bool p_src_closed,
		const PackedVector2Array &p_dst_pts, PackedFloat32Array &r_dst_widths,
		PackedFloat32Array &r_dst_heights) {
	bool have_w = p_src_widths.size() > 0;
	bool have_h = p_src_heights.size() > 0;
	int n = p_dst_pts.size();
	if (!have_w && !have_h) {
		r_dst_widths.clear();
		r_dst_heights.clear();
		return;
	}
	PackedFloat32Array cum = path_arc_lengths(p_src_pts, p_src_closed);
	if (have_w) {
		r_dst_widths.resize(n);
	}
	if (have_h) {
		r_dst_heights.resize(n);
	}
	float *w_ptr = have_w ? r_dst_widths.ptrw() : nullptr;
	float *h_ptr = have_h ? r_dst_heights.ptrw() : nullptr;
	const Vector2 *dst = p_dst_pts.ptr();

	for (int i = 0; i < n; ++i) {
		double s = path_project_s(p_src_pts, cum, dst[i], p_src_closed);
		if (have_w) {
			w_ptr[i] = path_sample_along(p_src_widths, cum, s, p_src_closed);
		}
		if (have_h) {
			h_ptr[i] = path_sample_along(p_src_heights, cum, s, p_src_closed);
		}
	}
}

float path_sample_grid(const PackedFloat32Array &p_grid, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_wx, double p_wz) {
	if (p_gw <= 0 || p_gh <= 0 || p_grid.size() < p_gw * p_gh) {
		return NAN;
	}
	double dx = p_rect.size.x / (double)p_gw;
	double dz = p_rect.size.y / (double)p_gh;
	if (dx <= 0.0 || dz <= 0.0) {
		return NAN;
	}
	if (p_wx < p_rect.position.x - 1.0e-4 || p_wx > p_rect.position.x + p_rect.size.x + 1.0e-4 ||
			p_wz < p_rect.position.y - 1.0e-4 || p_wz > p_rect.position.y + p_rect.size.y + 1.0e-4) {
		return NAN;
	}
	double fx = (p_wx - (p_rect.position.x + 0.5 * dx)) / dx;
	double fz = (p_wz - (p_rect.position.y + 0.5 * dz)) / dz;
	int x0 = (int)std::floor(fx);
	int z0 = (int)std::floor(fz);
	float tx = (float)(fx - (double)x0);
	float tz = (float)(fz - (double)z0);
	int x1 = x0 + 1;
	int z1 = z0 + 1;
	x0 = std::clamp(x0, 0, p_gw - 1);
	x1 = std::clamp(x1, 0, p_gw - 1);
	z0 = std::clamp(z0, 0, p_gh - 1);
	z1 = std::clamp(z1, 0, p_gh - 1);

	const float *grid = p_grid.ptr();
	float v00 = grid[z0 * p_gw + x0];
	float v10 = grid[z0 * p_gw + x1];
	float v01 = grid[z1 * p_gw + x0];
	float v11 = grid[z1 * p_gw + x1];
	if (!std::isfinite(v00) || !std::isfinite(v10) || !std::isfinite(v01) || !std::isfinite(v11)) {
		return NAN;
	}
	float top = v00 + (v10 - v00) * tx;
	float bot = v01 + (v11 - v01) * tx;
	return top + (bot - top) * tz;
}

PackedVector2Array path_ring_of(const PackedVector2Array &p_pts, bool p_closed) {
	if (p_closed && p_pts.size() >= 2) {
		PackedVector2Array r = p_pts;
		r.append(p_pts[0]);
		return r;
	}
	return p_pts;
}

PackedVector2Array path_unring(const PackedVector2Array &p_pts, bool p_closed) {
	int n = p_pts.size();
	if (p_closed && n >= 2 && p_pts[0].is_equal_approx(p_pts[n - 1])) {
		return p_pts.slice(0, n - 1);
	}
	return p_pts;
}

// ---- Derive Family (GRID -> PATH) -------------------------------------------

PackedFloat32Array path_drape_solve(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_existing_heights, bool p_closed,
		const PackedFloat32Array &p_grid, int p_gw, int p_gh, const Rect2 &p_rect,
		double p_offset, bool p_force_downhill, double p_min_drop) {
	int n = p_points.size();
	PackedFloat32Array hs;
	hs.resize(n);
	if (n == 0) {
		return hs;
	}
	float *hs_ptr = hs.ptrw();
	const Vector2 *pts = p_points.ptr();
	const float *prev_h_ptr = p_existing_heights.ptr();
	int prev_h_sz = p_existing_heights.size();

	for (int i = 0; i < n; ++i) {
		float h = path_sample_grid(p_grid, p_gw, p_gh, p_rect, pts[i].x, pts[i].y);
		if (!std::isfinite(h)) {
			float prev_h = (i < prev_h_sz) ? prev_h_ptr[i] : 0.0f;
			h = std::isfinite(prev_h) ? prev_h : 0.0f;
		}
		hs_ptr[i] = h + (float)p_offset;
	}

	if (p_force_downhill && n > 1 && !p_closed) {
		for (int i = 1; i < n; ++i) {
			float run = pts[i].distance_to(pts[i - 1]);
			float max_h = hs_ptr[i - 1] - (float)p_min_drop * run;
			if (hs_ptr[i] > max_h) {
				hs_ptr[i] = max_h;
			}
		}
	}
	return hs;
}

PackedFloat32Array path_width_field_solve(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_existing_widths,
		const PackedFloat32Array &p_field, int p_gw, int p_gh, const Rect2 &p_rect,
		double p_field_min, double p_field_max, double p_half_width_min, double p_half_width_max,
		const PackedFloat32Array &p_curve_lut, bool p_scale_existing, double p_min_half_width) {
	int n = p_points.size();
	PackedFloat32Array hw;
	hw.resize(n);
	if (n == 0) {
		return hw;
	}
	float *hw_ptr = hw.ptrw();
	const Vector2 *pts = p_points.ptr();
	const float *was_ptr = p_existing_widths.ptr();
	int was_sz = p_existing_widths.size();
	double span = p_field_max - p_field_min;
	int lut_sz = p_curve_lut.size();
	const float *lut = (lut_sz > 0) ? p_curve_lut.ptr() : nullptr;

	for (int i = 0; i < n; ++i) {
		float f = path_sample_grid(p_field, p_gw, p_gh, p_rect, pts[i].x, pts[i].y);
		float u = 0.0f;
		if (std::isfinite(f) && span > 0.0) {
			u = (float)Math::clamp((f - p_field_min) / span, 0.0, 1.0);
		}
		if (lut != nullptr && lut_sz > 1) {
			float fi = u * (lut_sz - 1);
			int idx0 = (int)std::floor(fi);
			int idx1 = std::min(idx0 + 1, lut_sz - 1);
			float frac = fi - (float)idx0;
			u = Math::clamp(lut[idx0] + (lut[idx1] - lut[idx0]) * frac, 0.0f, 1.0f);
		}
		float w = (float)(p_half_width_min + (p_half_width_max - p_half_width_min) * u);
		if (p_scale_existing) {
			float prev = 1.0f;
			if (was_sz > 0) {
				prev = was_ptr[std::min(i, was_sz - 1)];
			}
			w *= prev;
		}
		hw_ptr[i] = std::max(w, (float)p_min_half_width);
	}
	return hw;
}

static Vector2 path_flow_cell_centre(int p_ix, int p_iz, int p_gw, int p_gh, const Rect2 &p_rect) {
	double dx = p_rect.size.x / (double)std::max(p_gw, 1);
	double dz = p_rect.size.y / (double)std::max(p_gh, 1);
	return Vector2((real_t)(p_rect.position.x + ((double)p_ix + 0.5) * dx),
			(real_t)(p_rect.position.y + ((double)p_iz + 0.5) * dz));
}

Dictionary path_from_flow_solve(const PackedFloat32Array &p_flow,
		const PackedFloat32Array &p_surface, int p_gw, int p_gh, const Rect2 &p_rect,
		int p_seed_mode, const Vector2 &p_seed_point, double p_seed_radius,
		double p_min_flow, int p_step_cells, int p_max_points, double p_half_width) {
	Dictionary res;
	res["points"] = PackedVector2Array();
	res["half_widths"] = PackedFloat32Array();
	res["heights"] = PackedFloat32Array();

	int total_cells = p_gw * p_gh;
	if (total_cells <= 0 || p_flow.size() < total_cells) {
		return res;
	}
	const float *flow = p_flow.ptr();

	// Find seed cell
	int best = -1;
	float best_v = -1e30f;

	if (p_seed_mode == 1) { // POINT
		double dx = p_rect.size.x / (double)std::max(p_gw, 1);
		double dz = p_rect.size.y / (double)std::max(p_gh, 1);
		int cx = (int)std::floor((p_seed_point.x - p_rect.position.x) / std::max(dx, 1e-6));
		int cz = (int)std::floor((p_seed_point.y - p_rect.position.y) / std::max(dz, 1e-6));
		int rx = std::max((int)std::ceil(p_seed_radius / std::max(dx, 1e-6)), 0);
		int rz = std::max((int)std::ceil(p_seed_radius / std::max(dz, 1e-6)), 0);

		for (int iz = std::max(cz - rz, 0); iz < std::min(cz + rz + 1, p_gh); ++iz) {
			for (int ix = std::max(cx - rx, 0); ix < std::min(cx + rx + 1, p_gw); ++ix) {
				float v = flow[iz * p_gw + ix];
				if (std::isfinite(v) && v > best_v) {
					best_v = v;
					best = iz * p_gw + ix;
				}
			}
		}
	} else { // OUTLET
		for (int i = 0; i < total_cells; ++i) {
			float v = flow[i];
			if (std::isfinite(v) && v > best_v) {
				best_v = v;
				best = i;
			}
		}
	}

	if (best < 0 || best_v < (float)p_min_flow) {
		return res;
	}

	std::vector<uint8_t> seen(total_cells, 0);
	std::vector<int> cells;
	cells.reserve(std::min(p_max_points, 4096));

	int cur = best;
	seen[cur] = 1;
	cells.push_back(cur);

	while ((int)cells.size() < p_max_points) {
		// Best 8-neighbour
		auto get_best_neighbour = [&](int c) -> int {
			int cx = c % p_gw;
			int cz = c / p_gw;
			int b_idx = -1;
			float b_val = -1e30f;
			for (int oz = -1; oz <= 1; ++oz) {
				int z = cz + oz;
				if (z < 0 || z >= p_gh) continue;
				for (int ox = -1; ox <= 1; ++ox) {
					if (ox == 0 && oz == 0) continue;
					int x = cx + ox;
					if (x < 0 || x >= p_gw) continue;
					int idx = z * p_gw + x;
					if (seen[idx] != 0) continue;
					float v = flow[idx];
					if (std::isfinite(v) && v > b_val) {
						b_val = v;
						b_idx = idx;
					}
				}
			}
			return b_idx;
		};

		int nxt = get_best_neighbour(cur);
		if (nxt < 0) break;
		seen[nxt] = 1;
		cur = nxt;
		int stepped = 1;
		while (stepped < p_step_cells) {
			int s2 = get_best_neighbour(cur);
			if (s2 < 0) break;
			seen[s2] = 1;
			cur = s2;
			stepped++;
		}
		if (flow[cur] < (float)p_min_flow) {
			break;
		}
		cells.push_back(cur);
	}

	int n = cells.size();
	if (n < 2) {
		return res;
	}

	PackedVector2Array pts;
	pts.resize(n);
	Vector2 *pts_ptr = pts.ptrw();

	PackedFloat32Array hw;
	hw.resize(n);
	float *hw_ptr = hw.ptrw();

	for (int i = 0; i < n; ++i) {
		int c = cells[n - 1 - i]; // Reverse: upstream to downstream
		pts_ptr[i] = path_flow_cell_centre(c % p_gw, c / p_gw, p_gw, p_gh, p_rect);
		hw_ptr[i] = (float)p_half_width;
	}

	PackedFloat32Array hs;
	if (p_surface.size() >= total_cells) {
		hs.resize(n);
		float *hs_ptr = hs.ptrw();
		for (int i = 0; i < n; ++i) {
			float h = path_sample_grid(p_surface, p_gw, p_gh, p_rect, pts_ptr[i].x, pts_ptr[i].y);
			hs_ptr[i] = std::isfinite(h) ? h : 0.0f;
		}
	}

	res["points"] = pts;
	res["half_widths"] = hw;
	res["heights"] = hs;
	return res;
}

// ---- Reshape Family (PATH -> PATH) ------------------------------------------

static Vector2 path_catmull_rom(const Vector2 &p0, const Vector2 &p1, const Vector2 &p2, const Vector2 &p3, float t) {
	float t2 = t * t;
	float t3 = t2 * t;
	return 0.5f * ((p1 * 2.0f) + (-p0 + p2) * t + (p0 * 2.0f - p1 * 5.0f + p2 * 4.0f - p3) * t2 + (-p0 + p1 * 3.0f - p2 * 3.0f + p3) * t3);
}

static Vector2 path_interp_at(const PackedVector2Array &p_ring, const PackedFloat32Array &p_cum, double p_s, int p_method) {
	int n = p_ring.size();
	const Vector2 *ring = p_ring.ptr();
	const float *cum = p_cum.ptr();
	int i = 1;
	while (i < n - 1 && cum[i] < p_s) {
		i++;
	}
	float s0 = cum[i - 1];
	float s1 = cum[i];
	float t = (s1 <= s0) ? 0.0f : (float)Math::clamp((p_s - s0) / (s1 - s0), 0.0, 1.0);

	if (p_method == 0) { // LINEAR
		return ring[i - 1].lerp(ring[i], t);
	}
	Vector2 p0 = ring[std::max(i - 2, 0)];
	Vector2 p1 = ring[i - 1];
	Vector2 p2 = ring[i];
	Vector2 p3 = ring[std::min(i + 1, n - 1)];

	if (p_method == 3) { // BEZIER
		Vector2 c1 = p1 + (p2 - p0) / 6.0f;
		Vector2 c2 = p2 - (p3 - p1) / 6.0f;
		float u = 1.0f - t;
		return (p1 * (u * u * u) + c1 * (3.0f * u * u * t) + c2 * (3.0f * u * t * t) + p2 * (t * t * t));
	}
	if (p_method == 1) { // CUBIC
		return p1.cubic_interpolate(p2, p0, p3, t);
	}
	// CATMULL_ROM
	return path_catmull_rom(p0, p1, p2, p3, t);
}

Dictionary path_resample_solve(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_widths, const PackedFloat32Array &p_heights,
		bool p_closed, int p_method, double p_step, bool p_close) {
	Dictionary res;
	bool closed_out = p_closed || p_close;
	PackedVector2Array ring = path_ring_of(p_points, closed_out);
	if (ring.size() < 2 || p_step <= 0.0) {
		res["points"] = p_points;
		res["half_widths"] = p_widths;
		res["heights"] = p_heights;
		res["closed"] = closed_out;
		return res;
	}

	PackedFloat32Array cum = path_arc_lengths(ring, false);
	float total = cum[cum.size() - 1];
	if (total <= 0.0f) {
		res["points"] = p_points;
		res["half_widths"] = p_widths;
		res["heights"] = p_heights;
		res["closed"] = closed_out;
		return res;
	}

	int count = (int)std::floor(total / (float)p_step) + 1;
	if (count < 2 || count > PATH_OPS_MAX_POINTS) {
		res["points"] = p_points;
		res["half_widths"] = p_widths;
		res["heights"] = p_heights;
		res["closed"] = closed_out;
		return res;
	}

	PackedVector2Array pts;
	pts.resize(count);
	Vector2 *pts_ptr = pts.ptrw();
	for (int i = 0; i < count; ++i) {
		pts_ptr[i] = path_interp_at(ring, cum, std::min((double)i * p_step, (double)total), p_method);
	}

	if (pts[count - 1].distance_to(ring[ring.size() - 1]) > (float)p_step * 0.5f) {
		pts.append(ring[ring.size() - 1]);
	}

	PackedVector2Array out_pts = path_unring(pts, closed_out);
	PackedFloat32Array out_w, out_h;
	path_carry_values(p_points, p_widths, p_heights, p_closed, out_pts, out_w, out_h);

	res["points"] = out_pts;
	res["half_widths"] = out_w;
	res["heights"] = out_h;
	res["closed"] = closed_out;
	return res;
}

Dictionary path_smooth_solve(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_widths, const PackedFloat32Array &p_heights,
		bool p_closed, int p_window, double p_intensity, double p_inertia, bool p_pin_ends) {
	Dictionary res;
	res["points"] = p_points;
	res["half_widths"] = p_widths;
	res["heights"] = p_heights;

	if (p_window <= 0 || p_intensity <= 0.0 || p_points.size() < 3) {
		return res;
	}

	PackedVector2Array ring = path_ring_of(p_points, p_closed);
	int n = ring.size();
	PackedVector2Array out;
	out.resize(n);
	Vector2 *out_ptr = out.ptrw();
	const Vector2 *ring_ptr = ring.ptr();
	Vector2 prev = ring_ptr[0];

	for (int i = 0; i < n; ++i) {
		Vector2 acc = Vector2(0, 0);
		int cnt = 0;
		for (int k = -p_window; k <= p_window; ++k) {
			int j = i + k;
			if (p_closed) {
				j = ((j % (n - 1)) + (n - 1)) % (n - 1);
			} else {
				j = std::clamp(j, 0, n - 1);
			}
			acc += ring_ptr[j];
			cnt++;
		}
		Vector2 avg = acc / (float)cnt;
		Vector2 moved = ring_ptr[i].lerp(avg, (float)p_intensity);
		if (p_inertia > 0.0 && i > 0) {
			moved = moved.lerp(prev, (float)p_inertia);
		}
		if (p_pin_ends && !p_closed && (i == 0 || i == n - 1)) {
			moved = ring_ptr[i];
		}
		out_ptr[i] = moved;
		prev = moved;
	}

	if (p_closed && n >= 2) {
		out_ptr[n - 1] = out_ptr[0];
	}

	PackedVector2Array out_pts = path_unring(out, p_closed);
	PackedFloat32Array out_w, out_h;
	path_carry_values(p_points, p_widths, p_heights, p_closed, out_pts, out_w, out_h);

	res["points"] = out_pts;
	res["half_widths"] = out_w;
	res["heights"] = out_h;
	return res;
}

Dictionary path_decimate_solve(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_widths, const PackedFloat32Array &p_heights,
		bool p_closed, int p_target_points, double p_min_area) {
	Dictionary res;
	res["points"] = p_points;
	res["half_widths"] = p_widths;
	res["heights"] = p_heights;

	int n = p_points.size();
	int target = std::max(p_target_points, 3);
	if (n <= target) {
		return res;
	}

	std::vector<int> keep(n);
	for (int i = 0; i < n; ++i) {
		keep[i] = i;
	}

	const Vector2 *pts = p_points.ptr();
	int rounds = 0;
	constexpr int MAX_ROUNDS = 1000000;

	while ((int)keep.size() > target && rounds < MAX_ROUNDS) {
		rounds++;
		double worst = 1e30;
		int worst_at = -1;
		int lo = p_closed ? 0 : 1;
		int hi = p_closed ? (int)keep.size() : (int)keep.size() - 1;
		int k_sz = keep.size();

		for (int k = lo; k < hi; ++k) {
			int prev_idx = keep[((k - 1) % k_sz + k_sz) % k_sz];
			int cur_idx = keep[k];
			int next_idx = keep[(k + 1) % k_sz];
			Vector2 a = pts[prev_idx];
			Vector2 b = pts[cur_idx];
			Vector2 c = pts[next_idx];
			double area = Math::abs((b - a).cross(c - a)) * 0.5;
			if (area < worst) {
				worst = area;
				worst_at = k;
			}
		}

		if (worst_at < 0) {
			break;
		}
		if (p_min_area > 0.0 && worst >= p_min_area) {
			break;
		}
		keep.erase(keep.begin() + worst_at);
	}

	PackedVector2Array out_pts;
	out_pts.resize(keep.size());
	Vector2 *out_ptr = out_pts.ptrw();
	for (size_t i = 0; i < keep.size(); ++i) {
		out_ptr[i] = pts[keep[i]];
	}

	PackedFloat32Array out_w, out_h;
	path_carry_values(p_points, p_widths, p_heights, p_closed, out_pts, out_w, out_h);

	res["points"] = out_pts;
	res["half_widths"] = out_w;
	res["heights"] = out_h;
	return res;
}

// 1D Hash noise matching GDScript
static float path_hash1d(int k, int p_seed) {
	int64_t x = ((int64_t)k * 73856093LL) ^ ((int64_t)p_seed * 19349663LL) ^ 0x9e3779b9LL;
	x = ((x >> 16) ^ x) * 0x45d9f3bLL;
	x = ((x >> 16) ^ x) * 0x45d9f3bLL;
	x = (x >> 16) ^ x;
	return (float)((int64_t)(x & 0x7fffffffLL) % 2001 - 1000) / 1000.0f;
}

static float path_noise1d(float t, int p_seed, int p_closed_period = -1) {
	int i = (int)std::floor(t);
	float f = t - (float)i;
	float u = f * f * (3.0f - 2.0f * f);
	int i0 = i;
	int i1 = i + 1;
	if (p_closed_period > 0) {
		i0 = ((i0 % p_closed_period) + p_closed_period) % p_closed_period;
		i1 = ((i1 % p_closed_period) + p_closed_period) % p_closed_period;
	}
	float v0 = path_hash1d(i0, p_seed);
	float v1 = path_hash1d(i1, p_seed);
	return v0 + (v1 - v0) * u;
}

static PackedVector2Array path_subdivide_long_edges(const PackedVector2Array &p_pts, float p_max_len, bool p_closed) {
	int n = p_pts.size();
	if (n < 2 || p_max_len <= 0.0f) {
		return p_pts;
	}
	PackedVector2Array out;
	const Vector2 *pts = p_pts.ptr();
	for (int i = 0; i < n - 1; ++i) {
		Vector2 a = pts[i];
		Vector2 b = pts[i + 1];
		float d = (b - a).length();
		out.append(a);
		if (d > p_max_len) {
			int steps = std::clamp((int)std::ceil(d / p_max_len), 1, 32);
			for (int k = 1; k < steps; ++k) {
				out.append(a.lerp(b, (float)k / (float)steps));
			}
		}
	}
	out.append(pts[n - 1]);
	if (p_closed && out.size() >= 2) {
		out.set(out.size() - 1, out[0]);
	}
	return out;
}

Dictionary path_fractalize_solve(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_widths, const PackedFloat32Array &p_heights,
		bool p_closed, int p_orientation, double p_wavelength, double p_lacunarity,
		int p_iterations, double p_sigma, double p_persistence, int p_seed, bool p_pin_ends) {
	Dictionary res;
	res["points"] = p_points;
	res["half_widths"] = p_widths;
	res["heights"] = p_heights;

	if (p_iterations <= 0 || p_sigma <= 0.0 || p_points.size() < 2) {
		return res;
	}

	PackedVector2Array pts = path_ring_of(p_points, p_closed);
	if (pts.size() < 2) {
		return res;
	}

	double finest_wl = p_wavelength / std::pow(p_lacunarity, (double)(p_iterations - 1));
	double max_seg_len = Math::clamp(finest_wl * 0.5, 2.0, 50.0);
	pts = path_subdivide_long_edges(pts, (float)max_seg_len, p_closed);

	int n = pts.size();
	if (n < 2) {
		return res;
	}

	PackedFloat32Array s_arr = path_arc_lengths(pts, p_closed);
	float total_len = s_arr[s_arr.size() - 1];
	if (total_len <= 1e-5f) {
		return res;
	}

	PackedVector2Array new_pts = pts;
	Vector2 *new_ptr = new_pts.ptrw();
	const Vector2 *pts_ptr = pts.ptr();
	const float *s_ptr = s_arr.ptr();

	for (int i = 0; i < n; ++i) {
		bool is_end = (i == 0 || i == n - 1);
		if (is_end && !p_closed && p_pin_ends) {
			continue;
		}

		float s = s_ptr[i];
		double disp = 0.0;
		double amp = p_sigma;

		for (int o = 0; o < p_iterations; ++o) {
			double wl = p_wavelength / std::pow(p_lacunarity, (double)o);
			int period = -1;
			if (p_closed) {
				int m = std::max(1, (int)std::round(total_len / (float)wl));
				wl = total_len / (double)m;
				period = m;
			}
			int octave_seed = p_seed + o * 1013;
			disp += amp * (double)path_noise1d((float)(s / wl), octave_seed, period);
			amp *= p_persistence;
		}

		if (p_orientation == 1) { // LEFT
			disp = std::abs(disp);
		} else if (p_orientation == 2) { // RIGHT
			disp = -std::abs(disp);
		}

		if (!p_closed && p_pin_ends) {
			double taper_len = std::min(p_wavelength * 0.75, (double)total_len * 0.25);
			if (taper_len > 0.0) {
				double d0 = Math::clamp(s / taper_len, 0.0, 1.0);
				double d1 = Math::clamp(((double)total_len - s) / taper_len, 0.0, 1.0);
				disp *= (d0 * d0 * (3.0 - 2.0 * d0)) * (d1 * d1 * (3.0 - 2.0 * d1));
			}
		}

		int prev_i = p_closed ? (((i - 1) % (n - 1) + (n - 1)) % (n - 1)) : std::max(i - 1, 0);
		int next_i = p_closed ? (((i + 1) % (n - 1) + (n - 1)) % (n - 1)) : std::min(i + 1, n - 1);
		Vector2 prev_pt = pts_ptr[prev_i];
		Vector2 next_pt = pts_ptr[next_i];
		Vector2 seg = next_pt - prev_pt;
		float seg_len = seg.length();
		if (seg_len > 0.0f) {
			Vector2 nrm = Vector2(seg.y, -seg.x) / seg_len;
			new_ptr[i] = pts_ptr[i] + nrm * (float)disp;
		}
	}

	if (p_closed && n >= 2) {
		new_ptr[n - 1] = new_ptr[0];
	}

	PackedVector2Array out_pts = path_unring(new_pts, p_closed);
	PackedFloat32Array out_w, out_h;
	path_carry_values(p_points, p_widths, p_heights, p_closed, out_pts, out_w, out_h);

	res["points"] = out_pts;
	res["half_widths"] = out_w;
	res["heights"] = out_h;
	return res;
}

// 2D Segment intersection
static bool path_seg_intersect(const Vector2 &p1, const Vector2 &p2, const Vector2 &p3, const Vector2 &p4, Vector2 &r_pt) {
	Vector2 d1 = p2 - p1;
	Vector2 d2 = p4 - p3;
	float cross = d1.cross(d2);
	if (Math::abs(cross) < 1e-6f) return false;
	Vector2 d = p3 - p1;
	float t1 = d.cross(d2) / cross;
	float t2 = d.cross(d1) / cross;
	if (t1 > 0.001f && t1 < 0.999f && t2 > 0.001f && t2 < 0.999f) {
		r_pt = p1 + d1 * t1;
		return true;
	}
	return false;
}

static PackedVector2Array path_cut_loops(const PackedVector2Array &p_pts, bool p_closed) {
	PackedVector2Array pts = p_pts;
	bool changed = true;
	int passes = 0;
	constexpr int MAX_PASSES = 32;

	while (changed && passes < MAX_PASSES) {
		changed = false;
		passes++;
		int n = pts.size();
		int segs = p_closed ? (n >= 2 ? n - 1 : 0) : (n - 1);
		if (segs < 3) break;

		for (int i = 0; i < segs; ++i) {
			Vector2 a = pts[i];
			Vector2 b = pts[(i + 1) % n];
			for (int j = i + 2; j < segs; ++j) {
				if (p_closed && i == 0 && j == segs - 1) continue;
				Vector2 c = pts[j];
				Vector2 d = pts[(j + 1) % n];
				Vector2 x;
				if (path_seg_intersect(a, b, c, d, x)) {
					PackedVector2Array cut;
					if (p_closed) {
						int loop_forward = j - i;
						int loop_wrap = segs - loop_forward;
						if (loop_forward <= loop_wrap) {
							// Forward loop is shorter: excise i+1..j
							for (int k = 0; k <= i; ++k) cut.append(pts[k]);
							cut.append(x);
							for (int k = j + 1; k < n; ++k) cut.append(pts[k]);
						} else {
							// Wrap loop is shorter: excise wrap-around
							cut.append(x);
							for (int k = i + 1; k <= j; ++k) cut.append(pts[k]);
							cut.append(x);
						}
					} else {
						for (int k = 0; k <= i; ++k) cut.append(pts[k]);
						cut.append(x);
						for (int k = j + 1; k < n; ++k) cut.append(pts[k]);
					}
					pts = cut;
					changed = true;
					break;
				}
			}
			if (changed) break;
		}
	}
	return pts;
}

Dictionary path_meanderize_solve(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_widths, const PackedFloat32Array &p_heights,
		bool p_closed, double p_wavelength, double p_amplitude, double p_ratio,
		double p_noise_ratio, int p_seed, int p_iterations, double p_min_segment_length,
		int p_edge_divisions, bool p_remove_loops, bool p_pin_ends) {
	Dictionary res;
	res["points"] = p_points;
	res["half_widths"] = p_widths;
	res["heights"] = p_heights;

	if ((p_ratio <= 0.0 && p_noise_ratio <= 0.0) || p_iterations <= 0 || p_points.size() < 2) {
		return res;
	}

	PackedVector2Array pts = path_ring_of(p_points, p_closed);
	int seed = p_seed;

	float eff_amp = (float)(p_amplitude * (p_ratio + p_noise_ratio));
	if (eff_amp > 0.0f) {
		float max_seg_len = (float)std::max(p_wavelength / 4.0, p_min_segment_length);
		pts = path_subdivide_long_edges(pts, max_seg_len, p_closed);
		int n = pts.size();
		PackedFloat32Array s_arr = path_arc_lengths(pts, p_closed);
		float total_len = (s_arr.size() > 0) ? s_arr[s_arr.size() - 1] : 0.0f;

		if (total_len > 1e-4f && n >= 2) {
			float wl = (float)p_wavelength;
			if (p_closed) {
				int m = std::max(1, (int)Math::round(total_len / wl));
				wl = total_len / (float)m;
			}

			int64_t s_seed = (int64_t)p_seed;
			int64_t seed_prod = s_seed * 2654435761LL;
			int64_t pos_mod = ((seed_prod % 628318LL) + 628318LL) % 628318LL;
			float phi_0 = (float)pos_mod / 100000.0f;

			PackedVector2Array new_pts = pts;
			Vector2 *new_ptr = new_pts.ptrw();
			const Vector2 *cur_pts = pts.ptr();
			const float *s_ptr = s_arr.ptr();

			for (int i = 0; i < n; ++i) {
				bool is_end = (i == 0 || i == n - 1);
				if (is_end && !p_closed && p_pin_ends) {
					continue;
				}

				float s = s_ptr[i];
				float u = ((float)Math_TAU * s) / wl;
				float swing = Math::sin(u + phi_0);
				float harmonic = 0.3f * Math::sin(2.0f * u + phi_0 * 1.7f);
				float noise_val = path_noise1d(s / (wl * 0.5f), p_seed + 101);
				float disp = eff_amp * (swing + harmonic + (float)p_noise_ratio * noise_val);

				if (!p_closed && p_pin_ends) {
					float taper_len = (float)std::min(wl * 0.75f, total_len * 0.35f);
					if (taper_len > 0.0f) {
						float d0 = Math::clamp(s / taper_len, 0.0f, 1.0f);
						float d1 = Math::clamp((total_len - s) / taper_len, 0.0f, 1.0f);
						float env = (d0 * d0 * (3.0f - 2.0f * d0)) * (d1 * d1 * (3.0f - 2.0f * d1));
						disp *= env;
					}
				}

				int prev_i = p_closed ? (((i - 1) % (n - 1) + (n - 1)) % (n - 1)) : std::max(i - 1, 0);
				int next_i = p_closed ? (((i + 1) % (n - 1) + (n - 1)) % (n - 1)) : std::min(i + 1, n - 1);
				Vector2 seg = cur_pts[next_i] - cur_pts[prev_i];
				float seg_len = seg.length();
				if (seg_len > 0.0f) {
					Vector2 nrm = Vector2(seg.y, -seg.x) / seg_len;
					new_ptr[i] = cur_pts[i] + nrm * disp;
				}
			}

			if (p_closed && n >= 2) {
				new_ptr[n - 1] = new_ptr[0];
			}
			pts = new_pts;
		}
	}

	for (int it = 0; it < p_iterations; ++it) {
		int n = pts.size();
		if (n < 2 || n > PATH_OPS_MAX_POINTS) {
			break;
		}
		PackedVector2Array disp_pts = pts;
		Vector2 *disp_ptr = disp_pts.ptrw();
		const Vector2 *cur_pts = pts.ptr();

		for (int i = 0; i < n; ++i) {
			bool is_end = (i == 0 || i == n - 1);
			if (is_end && !p_closed && p_pin_ends) {
				continue;
			}

			int prev_i = p_closed ? (((i - 1) % (n - 1) + (n - 1)) % (n - 1)) : std::max(i - 1, 0);
			int next_i = p_closed ? (((i + 1) % (n - 1) + (n - 1)) % (n - 1)) : std::min(i + 1, n - 1);
			Vector2 p0 = cur_pts[prev_i];
			Vector2 p1 = cur_pts[i];
			Vector2 p2 = cur_pts[next_i];

			Vector2 chord_v = p2 - p0;
			float chord = chord_v.length();
			if (chord <= 1e-4f) {
				if (is_end && !p_closed && !p_pin_ends) {
					int adj_i = (i == 0) ? 1 : n - 2;
					Vector2 edge = (i == 0) ? (cur_pts[1] - cur_pts[0]) : (cur_pts[n - 1] - cur_pts[n - 2]);
					float elen = edge.length();
					if (elen > 1e-4f) {
						Vector2 enrm = Vector2(edge.y, -edge.x) / elen;
						float j = path_hash1d(i * 31 + it * 7, seed);
						disp_ptr[i] = cur_pts[i] + enrm * elen * (float)p_noise_ratio * j;
					}
				}
				continue;
			}

			Vector2 nrm = Vector2(chord_v.y, -chord_v.x) / chord;
			Vector2 v_in = p1 - p0;
			Vector2 v_out = p2 - p1;
			float turn = (chord > 1e-4f) ? (v_in.cross(v_out) / chord) : 0.0f;
			float jitter = path_hash1d(i * 31 + it * 7, seed);

			float disp = chord * ((float)p_ratio * turn + (float)p_noise_ratio * jitter);
			disp_ptr[i] = p1 + nrm * disp;
		}

		if (p_closed && n >= 2) {
			disp_ptr[n - 1] = disp_ptr[0];
		}

		// Edge division
		if (p_edge_divisions > 1) {
			PackedVector2Array div_pts;
			const Vector2 *dptr = disp_pts.ptr();
			for (int i = 0; i < n - 1; ++i) {
				Vector2 a = dptr[i];
				Vector2 b = dptr[i + 1];
				div_pts.append(a);
				float d = (b - a).length();
				if (d > (float)p_min_segment_length) {
					for (int k = 1; k < p_edge_divisions; ++k) {
						div_pts.append(a.lerp(b, (float)k / (float)p_edge_divisions));
					}
				}
			}
			div_pts.append(dptr[n - 1]);
			if (p_closed && div_pts.size() >= 2) {
				div_pts.set(div_pts.size() - 1, div_pts[0]);
			}
			disp_pts = div_pts;
		}

		if (p_remove_loops) {
			disp_pts = path_cut_loops(disp_pts, p_closed);
		}
		pts = disp_pts;
		seed += 1013;
	}

	PackedVector2Array out_pts = path_unring(pts, p_closed);
	PackedFloat32Array out_w, out_h;
	path_carry_values(p_points, p_widths, p_heights, p_closed, out_pts, out_w, out_h);

	res["points"] = out_pts;
	res["half_widths"] = out_w;
	res["heights"] = out_h;
	return res;
}

PackedFloat32Array path_width_solve(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_existing_widths, bool p_closed,
		int p_mode, double p_half_width, const PackedFloat32Array &p_along_lut,
		double p_min_half_width) {
	int n = p_points.size();
	PackedFloat32Array hw;
	hw.resize(n);
	if (n == 0) {
		return hw;
	}
	PackedFloat32Array cum = path_arc_lengths(p_points, p_closed);
	float total = (cum.size() > 0) ? cum[cum.size() - 1] : 0.0f;
	float *hw_ptr = hw.ptrw();
	const float *was_ptr = p_existing_widths.ptr();
	int was_sz = p_existing_widths.size();
	int lut_sz = p_along_lut.size();
	const float *lut = (lut_sz > 0) ? p_along_lut.ptr() : nullptr;

	for (int i = 0; i < n; ++i) {
		float w = (float)p_half_width;
		if (p_mode == 1) { // SCALE
			float prev = (was_sz > 0) ? was_ptr[std::min(i, was_sz - 1)] : 1.0f;
			w = prev * (float)p_half_width;
		}
		if (lut != nullptr && lut_sz > 1 && total > 0.0f) {
			float u = Math::clamp(cum[i] / total, 0.0f, 1.0f);
			float fi = u * (lut_sz - 1);
			int idx0 = (int)std::floor(fi);
			int idx1 = std::min(idx0 + 1, lut_sz - 1);
			float frac = fi - (float)idx0;
			float curve_val = lut[idx0] + (lut[idx1] - lut[idx0]) * frac;
			w *= curve_val;
		}
		hw_ptr[i] = std::max(w, (float)p_min_half_width);
	}
	return hw;
}

} // namespace godot
