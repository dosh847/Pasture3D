// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_leveler.h"

#include "pasture_3d_distance_transform.h"
#include "pasture_3d_thread_pool.h"

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <mutex>
#include <vector>

using namespace godot;

namespace {

constexpr int LEVELER_LUT_SIZE = 256;

// Linear lookup, the raster_ramp rule, in double — the oracle's GDScript floats are doubles.
double leveler_lut_sample(const float *p_lut, int p_n, double p_x) {
	const double x = std::clamp(p_x, 0.0, 1.0);
	const double f = x * (double)(p_n - 1);
	const int i0 = (int)f;
	if (i0 >= p_n - 1) {
		return (double)p_lut[p_n - 1];
	}
	const double frac = f - (double)i0;
	return (double)p_lut[i0] * (1.0 - frac) + (double)p_lut[i0 + 1] * frac;
}

// |slope| of the LUT interval containing x, over the steepest interval. 0 for a flat LUT.
double leveler_lut_slope(const float *p_lut, int p_n, double p_x, double p_max_step) {
	if (p_max_step <= 0.0) {
		return 0.0;
	}
	const int i0 = std::min((int)(std::clamp(p_x, 0.0, 1.0) * (double)(p_n - 1)), p_n - 2);
	return std::fabs((double)p_lut[i0 + 1] - (double)p_lut[i0]) / p_max_step;
}

} // namespace

Pasture3DLevelerParams godot::leveler_params_from(const float *p_params, int p_count) {
	auto at = [&](int p_k, double p_default) -> double {
		return (p_params != nullptr && p_k < p_count) ? (double)p_params[p_k] : p_default;
	};
	Pasture3DLevelerParams r;
	r.mode = (int)at(0, LEVELER_FLATTEN);
	r.statistic = (int)at(1, LEVELER_MEAN);
	r.target_height = at(2, 0.0);
	r.cut_fill = (int)at(3, LEVELER_BOTH);
	r.feather = std::max(at(4, 5.0), 0.0);
	r.feather_from_path_width = at(5, 0.0) > 0.5;
	r.path_width_scale = std::max(at(6, 1.0), 0.0);
	r.walls_shape = (int)at(7, LEVELER_BAND);
	r.wall_depth = std::max(at(8, 1.0), 0.0);
	r.median_bins = std::clamp((int)at(9, 4096.0), 16, 65536);
	r.feather_side = at(10, LEVELER_INSIDE) > 0.5 ? LEVELER_OUTSIDE : LEVELER_INSIDE;
	return r;
}

Dictionary godot::leveler_grid_geom(const Pasture3DPathGeom *p_loop, const PackedFloat32Array &p_height,
		const PackedFloat32Array &p_mask, int p_gw, int p_gh, const Rect2 &p_rect,
		const PackedFloat32Array &p_lut, const Pasture3DLevelerParams &p_params) {
	Dictionary out;
	const int n = p_gw * p_gh;
	if (p_gw <= 0 || p_gh <= 0 || p_height.size() != n) {
		out["ok"] = false;
		return out;
	}
	const float *h = p_height.ptr();
	const float *m = (p_mask.size() == n) ? p_mask.ptr() : nullptr;
	// Open and empty loops are ignored, as the oracle's set_path_inputs ignores them.
	const Pasture3DPathGeom *loop = (p_loop != nullptr && !p_loop->is_empty() && p_loop->closed) ? p_loop
																								  : nullptr;

	PackedFloat32Array o_height, o_mask, o_level, o_delta, o_walls;
	o_height.resize(n);
	o_mask.resize(n);
	o_level.resize(n);
	o_delta.resize(n);
	o_walls.resize(n);
	float *oh = o_height.ptrw();
	float *om = o_mask.ptrw();
	float *ol = o_level.ptrw();
	float *od = o_delta.ptrw();
	float *ow = o_walls.ptrw();
	std::copy_n(h, n, oh);
	std::fill_n(om, n, 0.f);
	std::fill_n(od, n, 0.f);
	std::fill_n(ow, n, 0.f);
	std::fill_n(ol, n, std::numeric_limits<float>::quiet_NaN());

	auto finish = [&](int64_t p_core, double p_level) -> Dictionary {
		out["ok"] = true;
		out["height"] = o_height;
		out["level_mask"] = o_mask;
		out["level_value"] = o_level;
		out["delta"] = o_delta;
		out["walls"] = o_walls;
		out["core_count"] = p_core;
		out["level"] = p_level;
		return out;
	};

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double min_x = (double)p_rect.position.x + 0.5 * dx;
	const double min_z = (double)p_rect.position.y + 0.5 * dz;

	// ---- 1. AREA: A per cell, the core I, and whether the mask shapes anything ----
	std::vector<float> area((size_t)n, 0.f);
	std::vector<uint8_t> core((size_t)n, 0);
	std::vector<int64_t> row_core((size_t)p_gh, 0);
	std::vector<uint8_t> row_shaped((size_t)p_gh, 0);
	std::vector<uint8_t> row_nonfinite((size_t)p_gh, 0);
	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			const double wz = min_z + (double)iz * dz;
			int64_t count = 0;
			uint8_t shaped = 0;
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = row + ix;
				if (!std::isfinite(h[i])) {
					row_nonfinite[(size_t)iz] = 1;
					continue;
				}
				double mv = m ? (double)m[i] : 1.0;
				mv = std::isfinite(mv) ? std::clamp(mv, 0.0, 1.0) : 0.0;
				if (mv < 1.0 - LEVELER_CORE_EPS) {
					shaped = 1;
				}
				double a = mv;
				if (loop != nullptr && !loop->inside(min_x + (double)ix * dx, wz)) {
					a = 0.0;
				}
				area[(size_t)i] = (float)a;
				if (a >= 1.0 - LEVELER_CORE_EPS) {
					core[(size_t)i] = 1;
					count++;
				}
			}
			row_core[(size_t)iz] = count;
			row_shaped[(size_t)iz] = shaped;
		}
	});
	int64_t core_count = 0;
	bool mask_trivial = true;
	bool any_nonfinite = false;
	for (int iz = 0; iz < p_gh; iz++) {
		core_count += row_core[(size_t)iz];
		if (row_shaped[(size_t)iz]) {
			mask_trivial = false;
		}
		if (row_nonfinite[(size_t)iz]) {
			any_nonfinite = true;
		}
	}
	if (core_count == 0) {
		return finish(0, std::numeric_limits<double>::quiet_NaN());
	}

	// ---- 2. LEVEL ----
	double level = p_params.target_height;
	if (p_params.mode != LEVELER_LEVEL_AT_HEIGHT) {
		// Per-row reductions in parallel, folded serially in row order.
		std::vector<double> row_sum((size_t)p_gh, 0.0);
		std::vector<double> row_lo((size_t)p_gh, std::numeric_limits<double>::infinity());
		std::vector<double> row_hi((size_t)p_gh, -std::numeric_limits<double>::infinity());
		Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
			for (int iz = z0; iz < z1; iz++) {
				const int row = iz * p_gw;
				double sum = 0.0;
				double lo = std::numeric_limits<double>::infinity();
				double hi = -std::numeric_limits<double>::infinity();
				for (int ix = 0; ix < p_gw; ix++) {
					const int i = row + ix;
					if (core[(size_t)i]) {
						const double v = (double)h[i];
						sum += v;
						lo = std::min(lo, v);
						hi = std::max(hi, v);
					}
				}
				row_sum[(size_t)iz] = sum;
				row_lo[(size_t)iz] = lo;
				row_hi[(size_t)iz] = hi;
			}
		});
		double lo = std::numeric_limits<double>::infinity();
		double hi = -std::numeric_limits<double>::infinity();
		for (int iz = 0; iz < p_gh; iz++) {
			lo = std::min(lo, row_lo[(size_t)iz]);
			hi = std::max(hi, row_hi[(size_t)iz]);
		}
		switch (p_params.statistic) {
			case LEVELER_MIN:
				level = lo;
				break;
			case LEVELER_MAX:
				level = hi;
				break;
			case LEVELER_MEDIAN: {
				if (hi <= lo) {
					level = lo;
					break;
				}
				const int bins = p_params.median_bins;
				const double span = hi - lo;
				std::vector<int64_t> hist((size_t)bins, 0);
				std::mutex merge;
				Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
					std::vector<int64_t> local((size_t)bins, 0);
					for (int iz = z0; iz < z1; iz++) {
						const int row = iz * p_gw;
						for (int ix = 0; ix < p_gw; ix++) {
							const int i = row + ix;
							if (core[(size_t)i]) {
								const int b = std::min((int)(((double)h[i] - lo) / span * (double)bins), bins - 1);
								local[(size_t)b]++;
							}
						}
					}
					// Integer counts: merge order cannot change the result.
					std::lock_guard<std::mutex> lock(merge);
					for (int b = 0; b < bins; b++) {
						hist[(size_t)b] += local[(size_t)b];
					}
				});
				const double k = 0.5 * (double)core_count;
				int64_t cum = 0;
				level = hi;
				for (int b = 0; b < bins; b++) {
					const int64_t c = hist[(size_t)b];
					if (c > 0 && (double)(cum + c) >= k) {
						level = lo + ((double)b + (k - (double)cum) / (double)c) * span / (double)bins;
						break;
					}
					cum += c;
				}
			} break;
			default: { // MEAN: rows folded in fixed blocks, blocks in order
				double total = 0.0;
				for (int z0 = 0; z0 < p_gh; z0 += LEVELER_MEAN_BLOCK_ROWS) {
					const int z1 = std::min(z0 + LEVELER_MEAN_BLOCK_ROWS, p_gh);
					double block = 0.0;
					for (int iz = z0; iz < z1; iz++) {
						block += row_sum[(size_t)iz];
					}
					total += block;
				}
				level = total / (double)core_count;
			} break;
		}
	}
	std::fill_n(ol, n, (float)level);

	// ---- 3. DISTANCE FROM THE CORE EDGE ----
	// OUTSIDE measures non-core cells to the nearest core cell. INSIDE measures core cells to the nearest
	// non-core cell or past the grid border, whichever is nearer. The exact route needs the polygon to BE the
	// edge; for INSIDE a non-finite cell is an edge too, so a footprint sends it to the raster route.
	const bool inside = p_params.feather_side == LEVELER_INSIDE;
	const bool exact = loop != nullptr && mask_trivial && (!inside || !any_nonfinite);
	PackedFloat32Array d_jfa;
	if (!exact) {
		PackedFloat32Array seed;
		seed.resize(n);
		float *sw = seed.ptrw();
		for (int i = 0; i < n; i++) {
			sw[i] = core[(size_t)i] ? 1.f : 0.f;
		}
		double divisor = 1.0;
		d_jfa = distance_transform_solve(seed, p_gw, p_gh, p_rect, 0.5,
				inside ? DISTANCE_TRANSFORM_INSIDE : DISTANCE_TRANSFORM_OUTSIDE,
				DISTANCE_TRANSFORM_EUCLIDEAN, DISTANCE_TRANSFORM_METRES, 0.0, &divisor);
		if (d_jfa.size() != n) {
			out["ok"] = false;
			return out;
		}
	}
	const float *dj = exact ? nullptr : d_jfa.ptr();
	const bool use_width = p_params.feather_from_path_width && loop != nullptr;

	// The falloff: the caller's table, or the analytic default baked exactly as the node bakes it.
	std::vector<float> lut_default;
	const float *lut = nullptr;
	int lut_n = 0;
	if (p_lut.size() >= 2) {
		lut = p_lut.ptr();
		lut_n = (int)p_lut.size();
	} else {
		lut_default.resize(LEVELER_LUT_SIZE);
		for (int i = 0; i < LEVELER_LUT_SIZE; i++) {
			const double x = (double)i / (double)(LEVELER_LUT_SIZE - 1);
			lut_default[(size_t)i] = (float)(1.0 - x * x * (3.0 - 2.0 * x));
		}
		lut = lut_default.data();
		lut_n = LEVELER_LUT_SIZE;
	}
	double max_step = 0.0;
	for (int i = 0; i < lut_n - 1; i++) {
		max_step = std::max(max_step, std::fabs((double)lut[i + 1] - (double)lut[i]));
	}

	// ---- 4. APPLY ----
	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		std::vector<int> scratch;
		scratch.reserve(32);
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			const double wz = min_z + (double)iz * dz;
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = row + ix;
				const double hv = (double)h[i];
				if (!std::isfinite(hv)) {
					continue;
				}
				const bool is_core = core[(size_t)i] != 0;
				const bool measured = inside ? is_core : !is_core;
				double d = 0.0;
				double s = 0.0;
				if (measured) {
					if (exact || use_width) {
						const Pasture3DPathHit hit = loop->nearest(min_x + (double)ix * dx, wz, scratch);
						s = hit.s;
						if (exact) {
							d = hit.distance;
						}
					}
					if (!exact) {
						d = (double)dj[i];
					}
					if (inside) {
						// The grid border is an edge: the cell one past it, centre to centre.
						d = std::min({ d, (double)(ix + 1) * dx, (double)(p_gw - ix) * dx, (double)(iz + 1) * dz,
								(double)(p_gh - iz) * dz });
					}
				}
				double fw = p_params.feather;
				if (use_width && measured) {
					fw = p_params.path_width_scale * loop->half_width_at(s);
				}

				double w = 1.0;
				double t = 0.0;
				bool in_ring = false;
				if (inside) {
					// x = 0 at the flat end of the wall, 1 at the untouched edge — the LUT's convention on
					// both sides, so one falloff curve reads the same way whichever side it is built on.
					if (is_core) {
						if (fw > 0.0 && d < fw) {
							t = 1.0 - d / fw;
							in_ring = true;
							w = leveler_lut_sample(lut, lut_n, t);
						}
					} else {
						w = (double)area[(size_t)i];
					}
				} else if (!is_core) {
					if (fw > 0.0 && d < fw) {
						t = d / fw;
						in_ring = true;
						w = std::max((double)area[(size_t)i], leveler_lut_sample(lut, lut_n, t));
					} else {
						w = (double)area[(size_t)i];
					}
				}
				if (w <= 0.0) {
					continue;
				}

				const double target = hv + (level - hv) * w;
				double ov = target;
				if (p_params.cut_fill == LEVELER_CUT_ONLY) {
					ov = std::min(hv, target);
				} else if (p_params.cut_fill == LEVELER_FILL_ONLY) {
					ov = std::max(hv, target);
				}
				const double delta = ov - hv;
				oh[i] = (float)ov;
				od[i] = (float)delta;
				if (p_params.cut_fill == LEVELER_BOTH || delta != 0.0) {
					om[i] = (float)w;
				}
				if (in_ring && delta != 0.0) {
					const double move = p_params.wall_depth <= 0.0
							? 1.0
							: std::clamp(std::fabs(delta) / p_params.wall_depth, 0.0, 1.0);
					const double shape = p_params.walls_shape == LEVELER_BAND
							? 1.0
							: leveler_lut_slope(lut, lut_n, t, max_step);
					ow[i] = (float)(move * shape);
				}
			}
		}
	});

	return finish(core_count, level);
}

Dictionary godot::leveler_grid(const PackedVector2Array &p_points, const PackedFloat32Array &p_widths,
		bool p_closed, const PackedFloat32Array &p_height, const PackedFloat32Array &p_mask, int p_gw,
		int p_gh, const Rect2 &p_rect, const PackedFloat32Array &p_lut,
		const Pasture3DLevelerParams &p_params) {
	if (p_points.size() < 2) {
		return leveler_grid_geom(nullptr, p_height, p_mask, p_gw, p_gh, p_rect, p_lut, p_params);
	}
	Pasture3DPathGeom geom;
	// Closed EXACTLY as the geometry table closes it (pasture_3d_graph_ops.cpp).
	geom.closed = p_closed && p_points.size() >= 3;
	geom.build(path_close_ring(p_points, geom.closed), p_widths);
	return leveler_grid_geom(&geom, p_height, p_mask, p_gw, p_gh, p_rect, p_lut, p_params);
}
