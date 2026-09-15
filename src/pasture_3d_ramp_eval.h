// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// The ONE C++ evaluation of a lowered Godot Gradient (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md §5).
//
// Transcribed from the PINNED engine, godotengine/godot tag 4.7-stable:
//   scene/resources/gradient.h:151-235   Gradient::get_color_at_offset (search, CONSTANT, LINEAR, CUBIC)
//   scene/resources/gradient.h:75-119    transform_color_space / inv_transform_color_space
//   core/math/color.h:192-204            Color::srgb_to_linear / linear_to_srgb
//   thirdparty/misc/ok_color.h:67-99     linear_srgb_to_oklab / oklab_to_linear_srgb
//   core/math/math_funcs.h               Math::cubic_interpolate (float)
// The oracle is Gradient.sample itself, so a transcription slip is a gate failure, not a judgement call.
// Arithmetic stays in float where the engine's does, including its double-precision constants.
//
// Stops are packed [offset, r, g, b, a] x n, SORTED BY THE ENGINE (the lowering samples the gradient once
// before reading its points, which runs Gradient::_update_sorting). Colours are sRGB, as the resource holds
// them. The GLSL twin is GRAPH_RAMP_EVAL_GLSL in pasture_3d_graph_gpu.cpp.

#pragma once

#include <cmath>

namespace godot {

// Sync with Gradient.InterpolationMode / Gradient.ColorSpace.
enum GraphRampMode {
	GRAPH_RAMP_LINEAR = 0,
	GRAPH_RAMP_CONSTANT = 1,
	GRAPH_RAMP_CUBIC = 2,
};

enum GraphRampSpace {
	GRAPH_RAMP_SRGB = 0,
	GRAPH_RAMP_LINEAR_SRGB = 1,
	GRAPH_RAMP_OKLAB = 2,
};

struct P3DRampColor {
	float r = 0.0f, g = 0.0f, b = 0.0f, a = 1.0f;
};

inline float p3d_ramp_srgb_to_linear(float x) {
	return x < 0.04045f ? x * (1.0f / 12.92f) : std::pow(float((x + 0.055) * (1.0 / (1.0 + 0.055))), 2.4f);
}

inline float p3d_ramp_linear_to_srgb(float x) {
	return x < 0.0031308f ? 12.92f * x : float((1.0 + 0.055) * std::pow(x, 1.0f / 2.4f) - 0.055);
}

inline P3DRampColor p3d_ramp_to_space(const P3DRampColor &c, int p_space) {
	if (p_space != GRAPH_RAMP_LINEAR_SRGB && p_space != GRAPH_RAMP_OKLAB) {
		return c;
	}
	P3DRampColor lin{ p3d_ramp_srgb_to_linear(c.r), p3d_ramp_srgb_to_linear(c.g), p3d_ramp_srgb_to_linear(c.b), c.a };
	if (p_space == GRAPH_RAMP_LINEAR_SRGB) {
		return lin;
	}
	const float l = 0.4122214708f * lin.r + 0.5363325363f * lin.g + 0.0514459929f * lin.b;
	const float m = 0.2119034982f * lin.r + 0.6806995451f * lin.g + 0.1073969566f * lin.b;
	const float s = 0.0883024619f * lin.r + 0.2817188376f * lin.g + 0.6299787005f * lin.b;
	const float l_ = std::cbrt(l);
	const float m_ = std::cbrt(m);
	const float s_ = std::cbrt(s);
	return {
		0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_,
		1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_,
		0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_,
		lin.a,
	};
}

inline P3DRampColor p3d_ramp_from_space(const P3DRampColor &c, int p_space) {
	if (p_space == GRAPH_RAMP_LINEAR_SRGB) {
		return { p3d_ramp_linear_to_srgb(c.r), p3d_ramp_linear_to_srgb(c.g), p3d_ramp_linear_to_srgb(c.b), c.a };
	}
	if (p_space != GRAPH_RAMP_OKLAB) {
		return c;
	}
	const float l_ = c.r + 0.3963377774f * c.g + 0.2158037573f * c.b;
	const float m_ = c.r - 0.1055613458f * c.g - 0.0638541728f * c.b;
	const float s_ = c.r - 0.0894841775f * c.g - 1.2914855480f * c.b;
	const float l = l_ * l_ * l_;
	const float m = m_ * m_ * m_;
	const float s = s_ * s_ * s_;
	const float lr = +4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s;
	const float lg = -1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s;
	const float lb = -0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s;
	return { p3d_ramp_linear_to_srgb(lr), p3d_ramp_linear_to_srgb(lg), p3d_ramp_linear_to_srgb(lb), c.a };
}

inline float p3d_ramp_cubic(float p_from, float p_to, float p_pre, float p_post, float p_weight) {
	return 0.5f *
			((p_from * 2.0f) + (-p_pre + p_to) * p_weight +
					(2.0f * p_pre - 5.0f * p_from + 4.0f * p_to - p_post) * (p_weight * p_weight) +
					(-p_pre + 3.0f * p_from - 3.0f * p_to + p_post) * (p_weight * p_weight * p_weight));
}

inline P3DRampColor p3d_ramp_stop(const float *p_stops, int p_k) {
	const float *q = p_stops + p_k * 5;
	return { q[1], q[2], q[3], q[4] };
}

// Gradient::get_color_at_offset, including its exact-hit early return (untransformed) and its search, so the
// equal-offset tie resolves the way the engine resolves it.
inline P3DRampColor p3d_ramp_sample(const float *p_stops, int p_n, int p_mode, int p_space, float p_offset) {
	if (p_n <= 0 || p_stops == nullptr) {
		return P3DRampColor{ 0.0f, 0.0f, 0.0f, 1.0f };
	}
	int low = 0;
	int high = p_n - 1;
	int middle = 0;
	while (low <= high) {
		middle = (low + high) / 2;
		const float off = p_stops[middle * 5];
		if (off > p_offset) {
			high = middle - 1;
		} else if (off < p_offset) {
			low = middle + 1;
		} else {
			return p3d_ramp_stop(p_stops, middle);
		}
	}
	if (p_stops[middle * 5] > p_offset) {
		middle--;
	}
	const int first = middle;
	const int second = middle + 1;
	if (second >= p_n) {
		return p3d_ramp_stop(p_stops, p_n - 1);
	}
	if (first < 0) {
		return p3d_ramp_stop(p_stops, 0);
	}
	const float weight = (p_offset - p_stops[first * 5]) / (p_stops[second * 5] - p_stops[first * 5]);
	switch (p_mode) {
		case GRAPH_RAMP_CONSTANT:
			return p3d_ramp_stop(p_stops, first);
		case GRAPH_RAMP_CUBIC: {
			int p0 = first - 1;
			int p3 = second + 1;
			if (p3 >= p_n) {
				p3 = second;
			}
			if (p0 < 0) {
				p0 = first;
			}
			const P3DRampColor c0 = p3d_ramp_to_space(p3d_ramp_stop(p_stops, p0), p_space);
			const P3DRampColor c1 = p3d_ramp_to_space(p3d_ramp_stop(p_stops, first), p_space);
			const P3DRampColor c2 = p3d_ramp_to_space(p3d_ramp_stop(p_stops, second), p_space);
			const P3DRampColor c3 = p3d_ramp_to_space(p3d_ramp_stop(p_stops, p3), p_space);
			P3DRampColor out{
				p3d_ramp_cubic(c1.r, c2.r, c0.r, c3.r, weight),
				p3d_ramp_cubic(c1.g, c2.g, c0.g, c3.g, weight),
				p3d_ramp_cubic(c1.b, c2.b, c0.b, c3.b, weight),
				p3d_ramp_cubic(c1.a, c2.a, c0.a, c3.a, weight),
			};
			return p3d_ramp_from_space(out, p_space);
		}
		case GRAPH_RAMP_LINEAR:
		default: {
			const P3DRampColor c1 = p3d_ramp_to_space(p3d_ramp_stop(p_stops, first), p_space);
			const P3DRampColor c2 = p3d_ramp_to_space(p3d_ramp_stop(p_stops, second), p_space);
			// Color::lerp is Math::lerp per channel: from + weight * (to - from).
			P3DRampColor out{
				c1.r + weight * (c2.r - c1.r),
				c1.g + weight * (c2.g - c1.g),
				c1.b + weight * (c2.b - c1.b),
				c1.a + weight * (c2.a - c1.a),
			};
			return p3d_ramp_from_space(out, p_space);
		}
	}
}

// Value Ramp's colour -> scalar. Sync with Pasture3DGraphNodeValueRamp.Channel. Read from the sRGB result.
inline float p3d_ramp_channel(const P3DRampColor &c, int p_channel) {
	switch (p_channel) {
		case 1: return 0.2126f * c.r + 0.7152f * c.g + 0.0722f * c.b;
		case 2: return c.r;
		case 3: return c.g;
		case 4: return c.b;
		case 5: return c.a;
		default: return (c.r + c.g + c.b) / 3.0f;
	}
}

} // namespace godot
