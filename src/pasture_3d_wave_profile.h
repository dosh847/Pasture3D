// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
// A named sea state, shared by every water body that selects it.
// Spec: PASTURE3D_WATER_BODIES_SPEC.md §5.3, PASTURE3D_WATER_FFT_SPEC.md §4

#ifndef PASTURE3D_WAVE_PROFILE_CLASS_H
#define PASTURE3D_WAVE_PROFILE_CLASS_H

#include <godot_cpp/classes/resource.hpp>

#include "constants.h"
#include "pasture_3d_water_fbm.h"
#include "pasture_3d_water_fft.h"

using namespace godot;

/**
 * One sea state: the FFT simulation, the fBm fallback's knobs, and the mesh density they need.
 *
 * The class exists so a scene can hold several of them and hand them out by name. Every piece of wave
 * arithmetic lives in Pasture3DWaterFFT and Pasture3DWaterFBM; this class only routes the CPU queries to
 * whichever one the materials draw.
 *
 * `fft` is the FFT sea for this profile: the simulation AND its knobs, as a sub-resource so the scene saves
 * them. `fbm` is the fallback's knobs, the same way. Which model a material draws is the manager's call, not
 * the profile's -- it depends on the renderer and the user's setting -- and the manager says which with
 * set_active_model().
 *
 * `loop_period` is not a property. water_time and water_time_period are project-wide shader globals, so the
 * period belongs to whatever owns the clock. Pasture3DPoolManager owns it and pushes it in with
 * set_loop_period().
 *
 * LEGACY KEYS. Profiles saved before Phase 6 of the FFT port carry the retired Gerstner knobs (wave_count,
 * direction_deg, spread_deg, amplitude, length_max, steepness). _set() accepts them on load and fits the
 * FFT and the fBm to them, exactly as those models were derived from them while Gerstner existed, but
 * only where the scene did not also store the model itself. Nothing reports them back, so resaving the
 * scene drops them (PASTURE3D_WATER_FFT_SPEC.md §6.6).
 */
class Pasture3DWaveProfile : public Resource {
	GDCLASS(Pasture3DWaveProfile, Resource);
	CLASS_NAME();

public: // Constants
	// What the materials on this profile draw. The values are the shader's `_wave_model` uniform
	// (water_common.gdshaderinc); 0 was Gerstner and is retired.
	enum ActiveModel {
		MODEL_FFT = 1,
		MODEL_FBM = 2,
	};

	// The fit's reference: the FFT's default sea is an ocean whose longest wave is this long. See fit_sea().
	static constexpr real_t REF_LENGTH = 137.f;
	// Height sigma per metre of the retired Gerstner amplitude sum: the ocean preset summed to 5.24 m
	// (unquantised) against the FFT ocean's sigma of 0.92 m.
	static constexpr real_t LEGACY_SIGMA_PER_AMP = 0.176f;

private:
	// The retired Gerstner knobs, as a loaded scene supplies them, with their old defaults. Only the ones
	// the fit reads are kept; spread_deg and steepness are accepted and dropped.
	struct LegacyKnobs {
		int count = 8;
		float direction_deg = 0.f;
		float amplitude = 1.6f;
		float length_max = 137.f;
	};
	// The period the legacy series was quantised at: water_time_period's default, which is what every
	// profile was built at while its scene loaded.
	static constexpr float LEGACY_LOOP_PERIOD = 120.f;
	// The old generator's wavelength floor.
	static constexpr float LEGACY_MIN_WAVELENGTH = 10.f;

	// Resource already has name/set_name (the resource's own name), so the
	// selection key is spelled out rather than overloading that.
	StringName _profile_name = "profile";
	Ref<Pasture3DWaterFFT> _fft;
	Ref<Pasture3DWaterFBM> _fbm;
	int _active_model = MODEL_FBM;
	real_t _loop_period = 120.f;
	real_t _min_wavelength = 10.f;
	LegacyKnobs _legacy;
	// False until an artist, a loaded scene or fit_sea() supplies the FFT's knobs. Until then they follow
	// the legacy keys, so a lake or pond saved before Phase 6 loads as a lake or a pond.
	bool _fft_authored = false;
	// The same for the fBm knobs.
	bool _fbm_authored = false;
	bool _deriving = false;

	// The FFT normal's half-step, metres. A quarter of the shortest default tile's 4 m wave would be 1 m;
	// this keeps the ripples a buoy should tilt on and smooths the ones its hull would average away.
	static constexpr real_t FFT_NORMAL_STEP = 0.25f;
	// The horizontal inverse's bound and tolerance.
	static constexpr int SOLVE_ITERATIONS = 16;
	static constexpr real_t SOLVE_EPSILON = 1e-4f;

	// The FFT's displaced point for a rest-domain point, off one readback.
	static Vector3 _fft_point(const Pasture3DWaterFFT::CpuSurface &p_surface, const Vector2 &p_domain_xz);
	// The readback, with the request that keeps the next ones coming.
	Pasture3DWaterFFT::CpuSurface _fft_surface();
	Vector3 _fbm_vertex(const Vector2 &p_domain_xz, const real_t p_time) const;

	void _on_fft_changed();
	void _on_fbm_changed();
	// Fits the models that are not authored (or both, with p_force) to a direction, size and height.
	void _fit(const real_t p_direction_deg, const real_t p_length_max, const real_t p_sigma, const bool p_force);
	// Re-fits the unauthored models from _legacy, and sets min_wavelength to the series' shortest wave.
	void _apply_legacy();

protected:
	static void _bind_methods();
	bool _set(const StringName &p_name, const Variant &p_value);

public:
	Pasture3DWaveProfile();
	~Pasture3DWaveProfile() {}

	void set_profile_name(const StringName &p_name);
	StringName get_profile_name() const { return _profile_name; }

	void set_fft(const Ref<Pasture3DWaterFFT> &p_fft);
	Ref<Pasture3DWaterFFT> get_fft() const { return _fft; }
	bool is_fft_authored() const { return _fft_authored; }

	void set_fbm(const Ref<Pasture3DWaterFBM> &p_fbm);
	Ref<Pasture3DWaterFBM> get_fbm() const { return _fbm; }
	bool is_fbm_authored() const { return _fbm_authored; }

	// The shortest wavelength the geometry must resolve. The water bodies mesh at an eighth of it (bodies
	// spec §7.3). A COST knob, not a correctness one: the FFT vertex stage picks its mip from whatever
	// spacing it is given (water_eval_fft) and the fBm drops the octaves it cannot draw, so a coarser mesh
	// loses short waves from the geometry while the fragment stage still draws them as slope.
	void set_min_wavelength(const real_t p_metres);
	real_t get_min_wavelength() const { return _min_wavelength; }

	// Fits both models to a sea `p_sigma` metres in height sigma whose longest wave is `p_length_max` metres
	// and runs along `p_direction_deg`. Overwrites whatever the knobs held, and counts as authoring them.
	void fit_sea(const real_t p_direction_deg, const real_t p_length_max, const real_t p_sigma);

	// Accepts one retired Gerstner key (see the class comment). True when the key was one. Public for
	// Pasture3D::migrate_ocean(), which carries an older generation of the same knobs.
	bool migrate_legacy_key(const StringName &p_name, const Variant &p_value);
	// The retired series, transcribed: the amplitude sum and the shortest wavelength a Gerstner table of
	// these knobs had. The only Gerstner arithmetic left, and it runs on load, never per frame.
	static void legacy_series(const int p_count, const float p_amplitude, const float p_length_max,
			const float p_loop_period, float &r_amplitude_sum, float &r_shortest);

	// Manager-driven, not exported. See the class comment. An ActiveModel value.
	void set_active_model(const int p_model);
	int get_active_model() const { return _active_model; }
	// True when materials on this profile draw the FFT: the manager chose it AND there is a simulation.
	bool is_fft_active() const { return _active_model == MODEL_FFT && _fft.is_valid(); }
	// True when they draw the fBm: anything but an active FFT, as long as there are knobs.
	bool is_fbm_active() const { return !is_fft_active() && _fbm.is_valid(); }
	void set_loop_period(const real_t p_seconds);
	real_t get_loop_period() const { return _loop_period; }

	// --- Derived, read-only -------------------------------------------------
	// How far the surface reaches from rest. Cull margins and clearance checks want this one. Under the FFT
	// it is the simulation's displacement bound, from the spectrum; under the fBm, the octaves' reach.
	real_t get_amplitude_sum();
	// The longest wave the drawn sea carries, metres: fit_sea()'s `length_max`, read back from the knobs.
	// Under the FFT, from the first cascade (the fit makes it 500/137 of the longest wave); under the fBm,
	// the first octave's wavelength. A METHOD, not a property: a `length_max` property would shadow the
	// legacy key of the same name, and _set() would never see it on load.
	real_t get_length_max() const;

	// --- Evaluation, in DOMAIN space ----------------------------------------
	// World-space queries live on the bodies, which add their own surface height
	// and subtract their own domain origin. These are the primitives underneath.
	//
	// They answer from the model the materials draw (PASTURE3D_WATER_FFT_SPEC.md §5):
	//   FBM       the vertex set, at p_time, every octave at full weight. Vertical only, so solve_domain()
	//             is the identity.
	//   FFT       the simulation's latest readback, and p_time is IGNORED: the answer is the surface as of
	//             the readback, one to three frames behind the clock (Pasture3DWaterFFT::get_cpu_surface).
	//             Every query keeps the readback running; the first one on a quiet sea starts it and
	//             answers a flat surface (height 0, normal up) until a frame lands.
	//   neither   no fbm and no active fft: flat.
	// The FFT normal is the displaced surface's, by central differences FFT_NORMAL_STEP either side.
	Vector3 get_surface_point(const Vector2 &p_domain_xz, const real_t p_time);
	real_t get_height_at(const Vector2 &p_domain_xz, const real_t p_time);
	Vector3 get_normal_at(const Vector2 &p_domain_xz, const real_t p_time);
	Vector2 solve_domain(const Vector2 &p_target_xz, const real_t p_time);
};

VARIANT_ENUM_CAST(Pasture3DWaveProfile::ActiveModel);

#endif // PASTURE3D_WAVE_PROFILE_CLASS_H
