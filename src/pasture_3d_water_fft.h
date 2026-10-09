// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef PASTURE3D_WATER_FFT_CLASS_H
#define PASTURE3D_WATER_FFT_CLASS_H

#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/texture2d_array_rd.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/vector4.hpp>

#include "constants.h"

using namespace godot;

/**
 * An FFT ocean surface: four cascades of Tessendorf waves on the main RenderingDevice.
 * Spec: PASTURE3D_WATER_FFT_SPEC.md §2. Ported from Garrett Gunnell's FFTWater (Unity).
 *
 * Owns the GPU resources and the per-frame dispatch, and nothing about bodies or materials: whoever holds
 * one calls update() once per frame with the shared water clock and hands the two Texture2DArrayRD
 * outputs to the materials that sample them.
 *
 * Runs on the MAIN rendering device, not a local one like the graph GPU's, because spatial materials have
 * to sample the outputs. Every RenderingDevice call therefore goes through call_on_render_thread().
 *
 * Outputs, N x N x 4 layers (one per cascade), rgba16f with a full mip chain:
 *   displacement  xyz = displacement in metres (x/z scaled by choppiness), a = foam in [0, 1+]
 *   slope         xy  = height slope d(y)/dx, d(y)/dz, z = Jacobian of the horizontal displacement
 * Cascade i tiles every cascade_lengths[i] metres.
 */
class Pasture3DWaterFFT : public RefCounted {
	GDCLASS(Pasture3DWaterFFT, RefCounted);
	CLASS_NAME();

public:
	static constexpr int CASCADES = 4;
	static constexpr float GRAVITY = 9.81f;

	enum Output {
		OUTPUT_INITIAL_SPECTRUM = 0,
		OUTPUT_SPECTRUM = 1,
		OUTPUT_DISPLACEMENT = 2,
		OUTPUT_SLOPE = 3,
	};

	// One JONSWAP spectrum's art knobs (the reference's DisplaySpectrumSettings).
	struct SpectrumKnobs {
		float scale = 1.f;
		float wind_speed = 10.f; // m/s
		float direction_deg = 0.f;
		float fetch = 100000.f; // m
		float spread_blend = 1.f;
		float swell = 0.2f;
		float peak_enhancement = 3.3f; // JONSWAP gamma
		float short_waves_fade = 0.01f; // m
	};

private:
	enum Kernel {
		K_INIT,
		K_PACK,
		K_UPDATE,
		K_FFT_H,
		K_FFT_V,
		K_ASSEMBLE,
		K_DOWNSAMPLE,
		K_COUNT,
	};

	// --- Knobs ---
	int _resolution = 256;
	int _seed = 1;
	float _depth = 100.f;
	float _choppiness = 1.f;
	float _loop_period = 120.f;
	// The longest tile must hold the swell's peak wavelength several times over, or the peak falls below
	// the grid's fundamental and a handful of modes carry the whole sea (measured: a 340 m swell on a 256 m
	// tile halved its variance when the tile moved to 180 m).
	Vector4 _cascade_lengths = Vector4(500.f, 85.f, 16.f, 4.f);
	bool _band_limited = true;
	SpectrumKnobs _spectra[2];
	float _foam_bias = 0.85f;
	float _foam_threshold = 0.f;
	float _foam_add = 6.f; // per second; the reference's 0.1 per frame at 60 fps
	float _foam_decay = 1.05f; // per second; the reference's 0.0175 per frame at 60 fps

	// --- GPU state. Touched only on the render thread. ---
	RenderingDevice *_rd = nullptr;
	int _built_resolution = 0;
	int _mip_count = 0;
	bool _init_failed = false;
	bool _spectrum_dirty = true;
	bool _params_dirty = true;
	RID _shaders[K_COUNT];
	RID _pipelines[K_COUNT];
	RID _params_buffer;
	RID _initial_tex;
	RID _spectrum_tex;
	RID _disp_tex;
	RID _slope_tex;
	// Storage views, one per (mip, cascade): [mip * CASCADES + cascade]. A storage binding writes a single
	// level, and this godot-cpp can only slice a layered texture into 2D views.
	Vector<RID> _disp_views;
	Vector<RID> _slope_views;
	RID _sets[K_DOWNSAMPLE]; // one uniform set per kernel, except the downsample's
	Vector<RID> _downsample_sets; // one per destination mip level (1..mips-1)
	int _update_count = 0;

	// --- Outputs. Resource wrappers that survive a resolution change: only their RID moves. ---
	Ref<Texture2DArrayRD> _disp_texture;
	Ref<Texture2DArrayRD> _slope_texture;

	bool _ensure_device();
	bool _compile_kernels();
	bool _build_resources();
	void _free_resources();
	void _free_kernels();
	RID _make_set(const Kernel p_kernel, const TypedArray<RDUniform> &p_uniforms);
	void _write_params();
	void _render_update(const float p_time, const float p_dt);
	PackedByteArray _render_read(const int p_output, const int p_layer, const int p_mip);

	void _knob_changed(const bool p_respectrum);

protected:
	static void _bind_methods();

public:
	Pasture3DWaterFFT();
	~Pasture3DWaterFFT();

	// Whether a RenderingDevice exists (Forward+ / Mobile). False under Compatibility and headless.
	static bool is_supported();
	bool is_available();

	void update(const float p_time, const float p_dt);
	int get_update_count() const { return _update_count; }

	Ref<Texture2DArrayRD> get_displacement_texture() const { return _disp_texture; }
	Ref<Texture2DArrayRD> get_slope_texture() const { return _slope_texture; }

	// The band each cascade keeps, |k| in [low, high), rad/m. Derived from the cascade lengths.
	Vector4 get_band_low() const;
	Vector4 get_band_high() const;

	// Synchronous readback of one layer at one mip level. Stalls the GPU: gates and debugging only.
	PackedByteArray read_layer(const int p_output, const int p_layer, const int p_mip = 0);

	// --- Knobs ---
	void set_resolution(const int p_resolution);
	int get_resolution() const { return _resolution; }
	void set_seed(const int p_seed);
	int get_seed() const { return _seed; }
	void set_depth(const float p_depth);
	float get_depth() const { return _depth; }
	void set_choppiness(const float p_choppiness);
	float get_choppiness() const { return _choppiness; }
	void set_loop_period(const float p_seconds);
	float get_loop_period() const { return _loop_period; }
	void set_cascade_lengths(const Vector4 &p_lengths);
	Vector4 get_cascade_lengths() const { return _cascade_lengths; }
	void set_band_limited(const bool p_enabled);
	bool get_band_limited() const { return _band_limited; }

	void set_spectrum_knob(const int p_spectrum, const StringName &p_knob, const float p_value);
	float get_spectrum_knob(const int p_spectrum, const StringName &p_knob) const;

	void set_foam_bias(const float p_value);
	float get_foam_bias() const { return _foam_bias; }
	void set_foam_threshold(const float p_value);
	float get_foam_threshold() const { return _foam_threshold; }
	void set_foam_add(const float p_value);
	float get_foam_add() const { return _foam_add; }
	void set_foam_decay(const float p_value);
	float get_foam_decay() const { return _foam_decay; }

	// The derived JONSWAP parameters the kernel receives, for the gate's CPU oracle:
	// [scale, angle_rad, spread_blend, swell, alpha, peak_omega, gamma, short_waves_fade].
	PackedFloat32Array get_spectrum_params(const int p_spectrum) const;
};

VARIANT_ENUM_CAST(Pasture3DWaterFFT::Output);

#endif // PASTURE3D_WATER_FFT_CLASS_H
