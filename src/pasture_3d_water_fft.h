// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef PASTURE3D_WATER_FFT_CLASS_H
#define PASTURE3D_WATER_FFT_CLASS_H

#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/texture2d_array_rd.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/vector4.hpp>

#include <atomic>
#include <mutex>

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
 * A RESOURCE so a Pasture3DWaveProfile can carry one as its `fft` sub-resource and the scene saves the
 * knobs. The GPU state is not a property and is never saved or duplicated; a duplicate builds its own.
 * `resolution` and `loop_period` are bound but not stored: Pasture3DPoolManager owns both and pushes
 * them in, as it does the Gerstner loop period.
 *
 * Runs on the MAIN rendering device, not a local one like the graph GPU's, because spatial materials have
 * to sample the outputs. Every RenderingDevice call therefore goes through call_on_render_thread().
 *
 * Outputs, N x N x 4 layers (one per cascade), rgba16f with a full mip chain:
 *   displacement  xyz = displacement in metres (x/z scaled by choppiness), a = foam in [0, 1+]
 *   slope         xy  = height slope d(y)/dx, d(y)/dz, z = Jacobian of the horizontal displacement
 * Cascade i simulates a cascade_lengths[i] metre tile and carries spectra 2i and 2i+1, as the reference does.
 * It is DRAWN repeating every get_cascade_repeats()[i] metres -- cascade_tiles, the reference's per-cascade
 * _Tile, which need not be the simulated length -- and only the cascades in cascade_drawn are simulated or
 * drawn at all, as the reference's visualizeLayer. PASTURE3D_WATER_REFERENCE_SPEC.md G1-G4.
 *
 * The CPU's copy of the surface (buoys, PASTURE3D_WATER_FFT_SPEC.md §5) is a readback of the displacement's
 * mip 0, taken only while something asks for it: see request_cpu_surface() and get_cpu_surface().
 */
class Pasture3DWaterFFT : public Resource {
	GDCLASS(Pasture3DWaterFFT, Resource);
	CLASS_NAME();

public:
	static constexpr int CASCADES = 4;
	// Two per cascade: the reference's spectrum1..spectrum8, index 0..7 here.
	static constexpr int SPECTRA = 2 * CASCADES;
	static constexpr float GRAVITY = 9.81f;
	// The FFT sizes offered. 1024 is the reference's; whether a device runs it is resolution_for_limits().
	static constexpr int MIN_RESOLUTION = 128;
	static constexpr int MAX_RESOLUTION = 1024;

	enum Output {
		OUTPUT_INITIAL_SPECTRUM = 0,
		OUTPUT_SPECTRUM = 1,
		OUTPUT_DISPLACEMENT = 2,
		OUTPUT_SLOPE = 3,
	};

	// How many updates the readback keeps running after the last CPU query: two seconds at 60 fps. A sea
	// nobody floats anything on reads nothing back, and one a buoy left a moment ago has not lost its copy.
	static constexpr int READBACK_KEEPALIVE = 120;
	// Readbacks in flight before the oldest is abandoned. A callback that never comes (a device lost
	// mid-frame) would otherwise grow the list for as long as the demand lasts.
	static constexpr int READBACK_MAX_PENDING = 8;

	// One frame of the displacement output, on the CPU: mip 0 of each layer as the GPU wrote it (rgba16f,
	// rows of N texels) and what it was dispatched with. Copying one is cheap -- the arrays are
	// copy-on-write -- so a query takes one copy and reads it for every tap it makes.
	struct CpuSurface {
		PackedByteArray layers[CASCADES];
		int resolution = 0;
		Vector4 repeats; // metres per tile as DRAWN: get_cascade_repeats()
		int displaces = 0; // the cascades summed, get_displacing_mask(); only these are read back
		float time = 0.f; // the water clock this frame was dispatched at
		int update = -1; // get_update_count() after that dispatch

		bool is_valid() const { return resolution > 0; }
		// The summed displacement (x, y, z) in metres at a rest-domain point, with the vertex shader's
		// texel convention (water_eval_fft): uv = domain / repeat, repeat-wrapped, bilinear between texel
		// centres at (i + 0.5) / N, over the displacing cascades only. Mip 0, so every cascade at full
		// detail. Zero when invalid.
		Vector3 sample(const Vector2 &p_domain_xz) const;
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
	// The defaults are the reference's SampleScene (PASTURE3D_WATER_REFERENCE_SPEC.md §2), set in the
	// constructor for the spectra. The lengths are in the scene's order, which is not descending.
	float _depth = 20.f;
	float _choppiness = 1.f;
	float _loop_period = 120.f;
	Vector4 _cascade_lengths = Vector4(94.f, 128.f, 64.f, 32.f);
	// The scene's tile_i are 0.01, 3, 3 and 0.13 per metre: these repeats. 0 means the cascade's length.
	Vector4 _cascade_tiles = Vector4(100.f, 1.f / 3.f, 1.f / 3.f, 1.f / 0.13f);
	int _cascade_drawn = 0b1001; // visualizeLayer1..4
	int _cascade_displaces = 0b0001; // contributeDisplacement1..4
	Vector4 _cascade_foam_offset = Vector4(0.04f, -0.04f, -0.46f, -0.38f); // foamSubtract1..4
	bool _band_limited = false;
	SpectrumKnobs _spectra[SPECTRA];
	float _foam_bias = 0.85f;
	// Added to the foam offsets' sum: ours, not the reference's (production spec W3). 0 is the reference.
	float _foam_lift = 0.f;
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
	// Bumped on the render thread each time the wrappers are pointed at new GPU textures; read on the main
	// thread by the manager, which re-uploads every material when it moves. See get_texture_generation().
	std::atomic<int> _texture_generation{ 0 };
	// Output textures kept alive across a resolution rebuild until the wrappers point at the new ones.
	Vector<RID> _retired_textures;

	// --- CPU readback. See request_cpu_surface(). ---
	// update() calls on the main thread, which the demand window counts in (_update_count is the render
	// thread's, and lags it when the renderer is threaded).
	int _main_updates = 0;
	int _cpu_demand_at = -(READBACK_KEEPALIVE + 1);
	struct PendingReadback {
		CpuSurface surface;
		int received = 0; // bit per layer
	};
	// The mutex covers both: callbacks arrive on the render thread, queries read on the main one.
	mutable std::mutex _readback_mutex;
	Vector<PendingReadback> _pending;
	CpuSurface _cpu_surface;
	int _readback_count = 0;

	// CPU estimate of the height standard deviation, from the spectrum integral. Cached: it is a few
	// thousand pow() calls and the cull bounds ask for it on every profile change.
	mutable float _sigma = 0.f;
	mutable bool _sigma_dirty = true;

	// --- Outputs. Resource wrappers that survive a resolution change: only their RID moves. ---
	Ref<Texture2DArrayRD> _disp_texture;
	Ref<Texture2DArrayRD> _slope_texture;

	bool _ensure_device();
	bool _compile_kernels();
	bool _build_resources();
	void _free_resources(const bool p_keep_outputs = false);
	void _free_retired();
	void _free_kernels();
	RID _make_set(const Kernel p_kernel, const TypedArray<RDUniform> &p_uniforms);
	void _write_params();
	void _render_update(const float p_time, const float p_dt, const bool p_readback);
	void _on_readback(const PackedByteArray &p_data, const int p_layer, const int p_update);
	PackedByteArray _render_read(const int p_output, const int p_layer, const int p_mip);

	void _knob_changed(const bool p_respectrum, const bool p_emit = true);

protected:
	static void _bind_methods();
	bool _set(const StringName &p_name, const Variant &p_value);
	bool _get(const StringName &p_name, Variant &r_ret) const;
	void _get_property_list(List<PropertyInfo> *p_list) const;

public:
	Pasture3DWaterFFT();
	~Pasture3DWaterFFT();

	// Whether a RenderingDevice exists (Forward+ / Mobile). False under Compatibility and headless.
	static bool is_supported();
	bool is_available();
	// A request snapped to the offered powers of two.
	static int snap_resolution(const int p_resolution);
	// The largest offered N, at most p_requested, that a device with these compute limits can run: one
	// workgroup of N threads per row, ping-ponging 2 * N vec4s (32 N bytes) of shared memory. Vulkan
	// guarantees only 16 KB and 128 invocations, so every N above 128 is a device question.
	static int resolution_for_limits(const int p_requested, const int64_t p_shared_bytes,
			const int64_t p_invocations, const int64_t p_size_x);
	// resolution_for_limits(MAX_RESOLUTION) on this device; MAX_RESOLUTION when there is none, since
	// nothing then runs and the CPU side may model any N.
	static int get_max_resolution();

	void update(const float p_time, const float p_dt);
	int get_update_count() const { return _update_count; }
	// How many times the output textures have been (re)built. A material DRAWN before the first build
	// holds the shader's default black array, not the wrapper: Texture2DArrayRD::get_rid() lazily makes a
	// plain 2D placeholder, a sampler2DArray uniform refuses that type and binds its default instead, and
	// the later texture_replace() never reaches a binding that does not reference the placeholder. (One
	// first drawn after the build binds correctly whenever it was uploaded.) Re-setting the parameter
	// after the build is what binds the real texture -- hence this count. WaterFFTWiringGate [B].
	int get_texture_generation() const { return _texture_generation.load(); }

	Ref<Texture2DArrayRD> get_displacement_texture() const { return _disp_texture; }
	Ref<Texture2DArrayRD> get_slope_texture() const { return _slope_texture; }

	// The band each cascade keeps, |k| in [low, high), rad/m. Derived from the cascade lengths. Without
	// band_limited every cascade keeps everything, as the reference does.
	Vector4 get_band_low() const;
	Vector4 get_band_high() const;

	// Synchronous readback of one layer at one mip level. Stalls the GPU: gates and debugging only.
	PackedByteArray read_layer(const int p_output, const int p_layer, const int p_mip = 0);

	// --- The CPU's surface (buoys) ---
	// Asks for the readback to run for the next READBACK_KEEPALIVE updates. Every CPU query calls it, so
	// the first query on a quiet sea starts the readback and answers from nothing: until the first frame
	// lands (one to three frames later) get_cpu_surface() is invalid.
	void request_cpu_surface() { _cpu_demand_at = _main_updates; }
	// The latest COMPLETE readback: all four layers of one dispatch. It describes the surface as of its
	// `time`, which is one to three frames behind the clock -- the GPU finishes a frame that long after it
	// was issued. A buoy reads a surface that recent, not the one being drawn.
	CpuSurface get_cpu_surface() const;
	int get_readback_count() const;
	int get_readback_update() const;
	float get_readback_time() const;
	Vector3 sample_cpu_displacement(const Vector2 &p_domain_xz) const { return get_cpu_surface().sample(p_domain_xz); }

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
	void set_cascade_tiles(const Vector4 &p_tiles);
	Vector4 get_cascade_tiles() const { return _cascade_tiles; }
	void set_cascade_drawn(const int p_mask);
	int get_cascade_drawn() const { return _cascade_drawn; }
	void set_cascade_displaces(const int p_mask);
	int get_cascade_displaces() const { return _cascade_displaces; }
	void set_cascade_foam_offset(const Vector4 &p_offset);
	Vector4 get_cascade_foam_offset() const { return _cascade_foam_offset; }

	// Metres per drawn tile: cascade_tiles, with 0 meaning the cascade's own length.
	Vector4 get_cascade_repeats() const;
	// The cascades that move the surface: displaces AND drawn, because the reference multiplies its
	// displacement by both flags. The height sigma, the bounds and the CPU surface all count only these.
	int get_displacing_mask() const { return _cascade_drawn & _cascade_displaces & 0xf; }
	// What the shader adds to the summed foam before it clamps: every cascade's offset, DRAWN OR NOT. The
	// reference adds _FoamSubtract_i after multiplying the sample by the layer's flag, so a hidden cascade
	// still subtracts its offset (the scene's total is -0.84 with two of four drawn).
	float get_foam_offset_sum() const;

	void set_spectrum_knob(const int p_spectrum, const StringName &p_knob, const float p_value);
	float get_spectrum_knob(const int p_spectrum, const StringName &p_knob) const;

	void set_foam_bias(const float p_value);
	float get_foam_bias() const { return _foam_bias; }
	void set_foam_lift(const float p_value);
	float get_foam_lift() const { return _foam_lift; }
	void set_foam_threshold(const float p_value);
	float get_foam_threshold() const { return _foam_threshold; }
	void set_foam_add(const float p_value);
	float get_foam_add() const { return _foam_add; }
	void set_foam_decay(const float p_value);
	float get_foam_decay() const { return _foam_decay; }

	// The derived JONSWAP parameters the kernel receives for spectrum 0..SPECTRA-1, for the gate's CPU oracle:
	// [scale, angle_rad, spread_blend, swell, alpha, peak_omega, gamma, short_waves_fade].
	PackedFloat32Array get_spectrum_params(const int p_spectrum) const;

	// Standard deviation of surface height in metres: the square root of the expected variance of the
	// modes the four cascades hold, each cascade its own pair of spectra. CPU, independent of the GPU, and
	// what the realised sea measures against (WaterFFTGate [P]). Significant wave height is 4x this.
	float get_height_sigma() const;
	// Vertical reach for cull volumes: 1.5 significant wave heights. The largest crest in a field of a
	// few thousand waves is about that, and a cull box that clips a rare crest pops it out of view.
	float get_displacement_bound() const { return 6.f * get_height_sigma(); }
	// The wavelength, metres, above which `p_fraction` of the displacing cascades' height variance lies:
	// 0.95 says which waves carry the sea's height, and so what a mesh must resolve
	// (Pasture3DWaveProfile::min_wavelength). A continuum integral over each displacing cascade's band, so
	// it ignores the low-ring discreteness get_height_sigma() sums mode by mode: it says WHERE the
	// variance is, not how much.
	float get_variance_wavelength(const float p_fraction) const;
};

VARIANT_ENUM_CAST(Pasture3DWaterFFT::Output);

#endif // PASTURE3D_WATER_FFT_CLASS_H
