// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_math_ops.h"
#include "pasture_3d_util.h"
#include "pasture_3d_thread_pool.h"

#include <algorithm>
#include <cmath>
#include <limits>

using namespace godot;

namespace {

// The one definition lives in pasture_3d_util.h. This forwarder keeps the call sites below unchanged
// while removing the sixth copy of a guard that returned a metres threshold as a 0..1 weight.
inline double smoothstep(double p_from, double p_to, double p_weight) {
	return ::smoothstep_d(p_from, p_to, p_weight);
}

} // namespace

PackedFloat32Array godot::curve_grid(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_lut,
		double p_in_min, double p_in_max, double p_out_min, double p_out_max, double p_amount) {
	const int n = p_surface.size();
	PackedFloat32Array out;
	out.resize(n);
	if (n <= 0) {
		return out;
	}

	const int lut_size = p_lut.size();
	if (lut_size < 2 || std::abs(p_amount) <= 1e-7) {
		return p_surface.duplicate();
	}

	const float *s_ptr = p_surface.ptr();
	const float *lut_ptr = p_lut.ptr();
	float *w = out.ptrw();

	const double span_in = p_in_max - p_in_min;
	const double span_out = p_out_max - p_out_min;
	const double lut_max_idx = (double)(lut_size - 1);

	Pasture3DThreadPool::parallel_for_elements(n, 1024, [&](int i0, int i1) {
		for (int i = i0; i < i1; i++) {
			const float x = s_ptr[i];
			if (std::isnan(x)) {
				w[i] = NAN;
				continue;
			}

			double u = 0.0;
			if (std::abs(span_in) > 1.0e-9) {
				u = std::clamp(((double)x - p_in_min) / span_in, 0.0, 1.0);
			}

			const double f_idx = u * lut_max_idx;
			const int idx0 = std::min((int)f_idx, lut_size - 2);
			const double frac = f_idx - (double)idx0;
			const double y = (double)lut_ptr[idx0] * (1.0 - frac) + (double)lut_ptr[idx0 + 1] * frac;

			const double remapped = p_out_min + y * span_out;
			w[i] = (float)((double)x + ((remapped - (double)x) * p_amount));
		}
	});

	return out;
}

PackedFloat32Array godot::remap_grid(const PackedFloat32Array &p_surface,
		double p_in_min, double p_in_max, double p_out_min, double p_out_max,
		bool p_clamp_output, double p_soft_knee, bool p_invert) {
	const int n = p_surface.size();
	PackedFloat32Array out;
	out.resize(n);
	if (n <= 0) {
		return out;
	}

	const float *s_ptr = p_surface.ptr();
	float *w = out.ptrw();

	const double span_in = p_in_max - p_in_min;
	const double span_out = p_out_max - p_out_min;
	const double k = p_soft_knee * 0.5;

	Pasture3DThreadPool::parallel_for_elements(n, 1024, [&](int i0, int i1) {
		for (int i = i0; i < i1; i++) {
			const float x = s_ptr[i];
			if (std::isnan(x)) {
				w[i] = NAN;
				continue;
			}

			double t = (std::abs(span_in) > 1.0e-9) ? (((double)x - p_in_min) / span_in) : 0.0;
			if (p_invert) {
				t = 1.0 - t;
			}

			if (p_clamp_output) {
				if (p_soft_knee > 0.0) {
					if (t < k) {
						const double st = t / k;
						t = 0.5 * k * st * st;
					} else if (t > (1.0 - k)) {
						const double st = (1.0 - t) / k;
						t = 1.0 - 0.5 * k * st * st;
					}
				}
				t = std::clamp(t, 0.0, 1.0);
			}

			w[i] = (float)(p_out_min + t * span_out);
		}
	});

	return out;
}

PackedFloat32Array godot::mask_grid(const PackedFloat32Array &p_surface, int p_gw, int p_gh,
		const Rect2 &p_rect, int p_property, double p_band_min, double p_band_max,
		double p_falloff_lo, double p_falloff_hi, bool p_invert, double p_strength) {
	const int n = p_gw * p_gh;
	PackedFloat32Array out;
	out.resize(n);
	if (n <= 0 || p_surface.size() != n) {
		return out;
	}

	const float *h = p_surface.ptr();
	float *w = out.ptrw();

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double inv2x = 1.0 / (2.0 * std::max(dx, 1.0e-9));
	const double inv2z = 1.0 / (2.0 * std::max(dz, 1.0e-9));
	const double rad_to_deg_c = 180.0 / Math_PI;

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			const int zm = std::max(iz - 1, 0) * p_gw;
			const int zp = std::min(iz + 1, p_gh - 1) * p_gw;

			for (int ix = 0; ix < p_gw; ix++) {
				const int xm = std::max(ix - 1, 0);
				const int xp = std::min(ix + 1, p_gw - 1);
				const float c = h[row + ix];

				if (std::isnan(c)) {
					w[row + ix] = 0.0f;
					continue;
				}

				double x = 0.0;
				if (p_property == GRAPH_MASK_ALTITUDE) {
					x = (double)c;
				} else if (p_property == GRAPH_MASK_SLOPE) {
					const double gx = ((double)h[row + xp] - (double)h[row + xm]) * inv2x;
					const double gz = ((double)h[zp + ix] - (double)h[zm + ix]) * inv2z;
					x = std::atan(std::sqrt(gx * gx + gz * gz)) * rad_to_deg_c;
				} else {
					// CURVATURE
					const double hxm = std::isnan(h[row + xm]) ? (double)c : (double)h[row + xm];
					const double hxp = std::isnan(h[row + xp]) ? (double)c : (double)h[row + xp];
					const double hzm = std::isnan(h[zm + ix]) ? (double)c : (double)h[zm + ix];
					const double hzp = std::isnan(h[zp + ix]) ? (double)c : (double)h[zp + ix];
					x = (hxm + hxp + hzm + hzp) * 0.25 - (double)c;
				}

				const double lo = p_band_min;
				const double hi = p_band_max;
				const double f_lo = std::max(p_falloff_lo, 0.0);
				const double f_hi = std::max(p_falloff_hi, 0.0);

				const double rise = (x >= lo) ? 1.0 : ((f_lo > 0.0) ? smoothstep(lo - f_lo, lo, x) : 0.0);
				const double fall = (x <= hi) ? 1.0 : ((f_hi > 0.0) ? 1.0 - smoothstep(hi, hi + f_hi, x) : 0.0);

				double weight = std::clamp(std::min(rise, fall), 0.0, 1.0);
				if (p_invert) {
					weight = 1.0 - weight;
				}

				w[row + ix] = (float)(1.0 + (weight - 1.0) * p_strength);
			}
		}
	});

	return out;
}

// --- Falloff (PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §4.2) ---------------------------------------
//
// Mirrors Pasture3DGraphNodeFalloff.attenuation / eval_cell. Distances are WORLD METRES taken from the
// cell centre via the same mapping as Pasture3DTerrainGraph.cell_to_world (dx divides by gw, sample at
// +0.5), so the falloff reads identically at any bake resolution and under any modifier margin.
PackedFloat32Array godot::falloff_grid(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_noise,
		int p_gw, int p_gh, const Rect2 &p_rect, int p_shape, double p_centre_x, double p_centre_z,
		double p_radius, double p_feather, double p_strength, bool p_invert, double p_distance_noise) {
	const int n = p_gw * p_gh;
	PackedFloat32Array result;
	result.resize(n);
	if (p_surface.size() != n || n <= 0) {
		return result;
	}

	const float *src = p_surface.ptr();
	const float *nz = (p_noise.size() == n) ? p_noise.ptr() : nullptr;
	float *dst = result.ptrw();

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double ox = (double)p_rect.position.x;
	const double oz = (double)p_rect.position.y;
	const double strength = std::clamp(p_strength, 0.0, 1.0);
	// Falloff's Shape is metrics 0-3. Anything else was RADIAL under the old switch's default, and must stay
	// RADIAL now that 4-7 mean something else to the shared metric.
	const int metric = (p_shape >= GRAPH_METRIC_RADIAL && p_shape <= GRAPH_METRIC_AXIS_Z) ? p_shape : GRAPH_METRIC_RADIAL;

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			const double wz = oz + ((double)iz + 0.5) * dz;
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = row + ix;
				const double v = (double)src[i];
				if (!std::isfinite(v)) {
					dst[i] = src[i]; // NaN is the loop mask; it survives untouched.
					continue;
				}

				const double wx = ox + ((double)ix + 0.5) * dx;
				// The shared metric (pasture_3d_distance_metric.h). Falloff is axis-aligned, so its frame is the
				// literal +X, for which the metric's rotation is exact.
				double d = p3d_distance_metric(metric, wx, wz, p_centre_x, p_centre_z, 1.0, 0.0);
				if (nz != nullptr && std::isfinite(nz[i])) {
					d += p_distance_noise * (double)nz[i];
				}

				// A zero feather is a hard edge, not a divide by zero.
				double t;
				if (p_feather <= 0.0) {
					t = (d <= p_radius) ? 0.0 : 1.0;
				} else {
					const double u = std::clamp((d - p_radius) / p_feather, 0.0, 1.0);
					t = u * u * (3.0 - 2.0 * u);
				}

				double a = 1.0 - t;
				if (p_invert) {
					a = 1.0 - a;
				}

				dst[i] = (float)(v * (1.0 + (a - 1.0) * strength));
			}
		}
	});

	return result;
}

// --- Contrast (PASTURE3D_GRAPH_TRANSFORMS_METRICS_SPEC.md §4.3) --------------------------------------
//
// Mirrors Pasture3DGraphNodeContrast.eval_cell. Heights OUTSIDE the window pass through untouched rather
// than being clamped into it — clamping would flatten every peak above the window into a plateau.
// --- Gradient (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md §4) ------------------------------------------
//
// Mirrors Pasture3DGraphNodeGradient.eval_cell, the oracle. start / end arrive in the node's space with
// the host placement beside them, and are placed HERE rather than in native_lower, because a driven
// start_x is resolved into P after lowering and has to be transformed exactly like the property.

// Shape -> shared metric. Sync with Pasture3DGraphNodeGradient.Shape.
static const int k_gradient_metric[7] = {
	GRAPH_METRIC_LINEAR, GRAPH_METRIC_REFLECTED, GRAPH_METRIC_RADIAL, GRAPH_METRIC_RADIAL,
	GRAPH_METRIC_SQUARE, GRAPH_METRIC_DIAMOND, GRAPH_METRIC_ANGULAR,
};

GradientFrame godot::gradient_frame(const float *p_params) {
	GradientFrame f;
	const int shape = std::clamp((int)p_params[0], 0, 6);
	f.metric = k_gradient_metric[shape];
	const double c = std::cos((double)p_params[15]);
	const double s = std::sin((double)p_params[15]);
	const double ox = (double)p_params[13];
	const double oz = (double)p_params[14];
	const double sx = (double)p_params[1], sz = (double)p_params[2];
	const double ex = (double)p_params[3], ez = (double)p_params[4];
	f.ax = ox + c * sx - s * sz;
	f.az = oz + s * sx + c * sz;
	const double bx = ox + c * ex - s * ez;
	const double bz = oz + s * ex + c * ez;
	f.len = std::max(std::sqrt((bx - f.ax) * (bx - f.ax) + (bz - f.az) * (bz - f.az)), 1.0e-3);
	p3d_metric_direction(f.ax, f.az, bx, bz, f.ux, f.uz);
	return f;
}

PackedFloat32Array godot::gradient_grid(const PackedFloat32Array &p_warp, int p_gw, int p_gh, const Rect2 &p_rect,
		const float *p_params, const PackedFloat32Array &p_lut) {
	const int n = p_gw * p_gh;
	PackedFloat32Array result;
	result.resize(n);
	if (n <= 0) {
		return result;
	}
	const GradientFrame fr = gradient_frame(p_params);
	const int shape = std::clamp((int)p_params[0], 0, 6);
	const double hmin = (double)p_params[5];
	const double hmax = (double)p_params[6];
	const int profile = (int)p_params[7];
	const double hardness = std::clamp((double)p_params[8], 0.05, 16.0);
	const int repeat = (int)p_params[9];
	const bool invert = p_params[10] > 0.5f;
	const bool height = p_params[11] > 0.5f;
	const double dnoise = (double)p_params[12];
	const double warp_scale = shape == 6 ? dnoise / fr.len : dnoise;

	const float *wp = (p_warp.size() == n) ? p_warp.ptr() : nullptr;
	const int lut_n = p_lut.size();
	const float *lut = p_lut.ptr();
	float *dst = result.ptrw();

	const double dx = (double)p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = (double)p_rect.size.y / (double)std::max(p_gh, 1);
	const double ox = (double)p_rect.position.x;
	const double oz = (double)p_rect.position.y;

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			const double wz = oz + ((double)iz + 0.5) * dz;
			for (int ix = 0; ix < p_gw; ix++) {
				const int i = row + ix;
				const double wx = ox + ((double)ix + 0.5) * dx;
				double d = p3d_distance_metric(fr.metric, wx, wz, fr.ax, fr.az, fr.ux, fr.uz);
				if (wp != nullptr && std::isfinite(wp[i])) {
					d += warp_scale * (double)wp[i];
				}
				double t;
				// SPHERICAL folds u = d / L and domes it after repeat; 1 - d/L would dome the wrong side.
				if (shape <= 1 || shape == 3) {
					t = d / fr.len;
				} else if (shape == 6) {
					t = d / (2.0 * 3.14159265358979323846);
				} else {
					t = 1.0 - d / fr.len;
				}
				t = p3d_repeat(repeat, t);
				if (shape == 3) {
					t = std::sqrt(std::max(0.0, 1.0 - t * t));
				}
				switch (profile) {
					case 1: t = t * t * (3.0 - 2.0 * t); break;
					case 2: t = t * t; break;
					case 3: t = 1.0 - (1.0 - t) * (1.0 - t); break;
					case 4: t = std::pow(std::max(t, 0.0), hardness); break;
					case 5:
						if (lut_n >= 2) {
							const double f_idx = std::clamp(t, 0.0, 1.0) * (double)(lut_n - 1);
							const int i0 = std::min((int)f_idx, lut_n - 2);
							const double frac = f_idx - (double)i0;
							t = (double)lut[i0] * (1.0 - frac) + (double)lut[i0 + 1] * frac;
						}
						break;
					default: break;
				}
				if (invert) {
					t = 1.0 - t;
				}
				dst[i] = (float)(height ? hmin + (hmax - hmin) * t : t);
			}
		}
	});
	return result;
}

PackedFloat32Array godot::contrast_grid(const PackedFloat32Array &p_surface, const PackedFloat32Array &p_mask,
		int p_mode, double p_amount, double p_range_min, double p_range_max, double p_mask_amount,
		bool p_explicit_window) {
	const int n = p_surface.size();
	PackedFloat32Array result;
	result.resize(n);
	if (n <= 0) {
		return result;
	}

	const float *src = p_surface.ptr();
	const float *msk = (p_mask.size() == n) ? p_mask.ptr() : nullptr;
	float *dst = result.ptrw();

	// Mirrors Pasture3DGraphNodeContrast.resolve_window: the authored metres, or the surface's own finite
	// extremes. Auto is the default, so the common path pays one linear scan before the shaping loop.
	double lo = p_range_min;
	double hi = p_range_max;
	if (!p_explicit_window) {
		lo = std::numeric_limits<double>::infinity();
		hi = -std::numeric_limits<double>::infinity();
		for (int i = 0; i < n; i++) {
			const double v = (double)src[i];
			if (std::isfinite(v)) {
				lo = std::min(lo, v);
				hi = std::max(hi, v);
			}
		}
		if (!std::isfinite(lo) || !std::isfinite(hi)) {
			// Nothing finite to measure. Pass through rather than invent a window.
			std::copy(src, src + n, dst);
			return result;
		}
	}

	const double span = hi - lo;
	if (span <= 0.0) {
		// A degenerate window has no defined normalisation; pass through rather than invent one.
		std::copy(src, src + n, dst);
		return result;
	}

	const double amount = std::max(p_amount, 0.001);
	const double mask_amount = std::clamp(p_mask_amount, 0.0, 1.0);

	Pasture3DThreadPool::parallel_for_elements(n, 1024, [&](int i0, int i1) {
		for (int i = i0; i < i1; i++) {
			const double v = (double)src[i];
			if (!std::isfinite(v)) {
				dst[i] = src[i];
				continue;
			}
			if (v <= lo || v >= hi) {
				dst[i] = src[i];
				continue;
			}

			const double t = (v - lo) / span;
			double c;
			if (p_mode == GRAPH_CONTRAST_GAMMA) {
				c = std::pow(t, amount);
			} else if (t < 0.5) {
				c = 0.5 * std::pow(2.0 * t, amount);
			} else {
				c = 1.0 - 0.5 * std::pow(2.0 - 2.0 * t, amount);
			}

			const double shaped = lo + c * span;
			double w = mask_amount;
			if (msk != nullptr && std::isfinite(msk[i])) {
				w *= (double)msk[i];
			}
			w = std::clamp(w, 0.0, 1.0);
			dst[i] = (float)(v + (shaped - v) * w);
		}
	});

	return result;
}
