// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/core/class_db.hpp>

#include <cmath>

#include "logger.h"
#include "pasture_3d_wave_profile.h"

///////////////////////////
// Public Functions
///////////////////////////

// Every setter emits changed() WHEN IT CHANGES SOMETHING. Pasture3DPoolManager listens for
// it and re-uploads the table into the materials it has cached for this profile -- which is
// what makes dragging a knob in the inspector move ten ponds at once, and is the only reason
// the manager does not have to poll.
//
// The guard is not a micro-optimisation. One emission reaches _on_profile_changed(), which
// re-uploads into EVERY cached material and then emits profiles_changed, which makes every
// Pasture3DOcean rebuild its runtime material and force an AABB update. These used to emit
// unconditionally while the WaterWaves setters underneath quietly no-opped, so loading a
// scene -- where Godot writes each exported property once, at its stored value -- cost four
// seeded profiles x six setters = 24 full re-upload passes over the cache for values that
// had not moved.
//
// Compared against what WaterWaves actually STORED, not against the argument: every setter
// there clamps, so set_spread_deg(200) stores 90, and comparing against the argument would
// make that emit forever.

Pasture3DWaveProfile::Pasture3DWaveProfile() {
	Ref<Pasture3DWaterFFT> fft;
	fft.instantiate();
	set_fft(fft);
	Ref<Pasture3DWaterFBM> fbm;
	fbm.instantiate();
	set_fbm(fbm);
	// The defaults are not authored ones: they follow the Gerstner knobs until edited.
	_fft_authored = false;
	_fbm_authored = false;
	_derive_models();
}

void Pasture3DWaveProfile::_on_fft_changed() {
	if (!_deriving) {
		_fft_authored = true;
	}
	emit_changed();
}

void Pasture3DWaveProfile::_on_fbm_changed() {
	if (!_deriving) {
		_fbm_authored = true;
	}
	emit_changed();
}

/**
 * Fits the FFT sea to the Gerstner knobs, for a profile whose FFT nobody has authored.
 *
 * The simulation's defaults are an ocean (WaterFFTGate's sea: Hs 3.7 m, peaks near 57 m and 133 m). This
 * keeps that sea's SHAPE and rescales it twice, which is the least that turns it into the body the
 * Gerstner knobs describe:
 *
 *   SIZE by r = length_max / 137 m, the ocean preset's longest wave. Every cascade length scales by r, and
 *   so does each spectrum's peak wavelength -- by scaling fetch, since at fixed wind the JONSWAP peak goes
 *   as (U F)^0.66, so F scales as r^(1/0.66). A pond's tiles shrink with its waves, and the peak stays
 *   inside the longest tile.
 *
 *   HEIGHT by the Gerstner amplitude sum. The ocean preset sums to 5.24 m against the FFT ocean's sigma
 *   of 0.92 m, so the target sigma is 0.176 x the sum, and `scale` (variance, so squared) moves both
 *   spectra together to reach it.
 *
 * Depth is left deep (100 m): a TMA-limited shallow sea is a choice a body's author makes, not one the
 * Gerstner knobs encode. Wind speed is left alone because scale and fetch already carry both axes.
 */
void Pasture3DWaveProfile::_derive_fft() {
	if (_fft_authored || _fft.is_null()) {
		return;
	}
	_ensure_built();
	const float ref_length = 137.f;
	const float ref_sigma_per_amp = 0.176f;
	const Vector4 ref_lengths(500.f, 85.f, 16.f, 4.f);
	const float ref_fetch[2] = { 100000.f, 300000.f };
	const float ref_scale[2] = { 1.f, 0.5f };
	float r = CLAMP(_waves.get_length_max() / ref_length, 0.01f, 20.f);
	_deriving = true;
	_fft->set_cascade_lengths(ref_lengths * r);
	for (int i = 0; i < 2; i++) {
		_fft->set_spectrum_knob(i, "fetch", ref_fetch[i] * std::pow(r, 1.f / 0.66f));
		_fft->set_spectrum_knob(i, "scale", ref_scale[i]);
	}
	float target = ref_sigma_per_amp * (float)_waves.get_amplitude_sum();
	float sigma = _fft->get_height_sigma();
	float gain = sigma > 1e-6f ? (target / sigma) * (target / sigma) : 0.f;
	for (int i = 0; i < 2; i++) {
		_fft->set_spectrum_knob(i, "scale", ref_scale[i] * gain);
	}
	_deriving = false;
}

/**
 * Fits the fBm to the Gerstner knobs, for a profile whose fBm nobody has authored.
 *
 * The reference's knobs are its look; this keeps all of them except the four that say WHERE and HOW BIG:
 *
 *   DIRECTION. The first octave runs along direction_deg (`seed` is that angle in radians).
 *   SIZE. `frequency` is 2 pi / length_max, so the first octave is the longest Gerstner wave. The rest of the
 *     series is relative to it (Pasture3DWaterFBM's class comment), so the shape scales with it.
 *   SPEED. The reference runs 2 rad/s at 1 rad/m, which is 0.64 of deep-water dispersion sqrt(g k). Kept as
 *     that fraction: speed = 2 sqrt(k), so a pond's ripples do not crawl and an ocean's swell does not race.
 *   HEIGHT. The same target as the FFT's: sigma = 0.176 x the Gerstner amplitude sum, from the closed-form
 *     sigma of the vertex set. The fragment set is then scaled so its first octaves are the SAME metres as
 *     the vertex set's -- the reference normalises each set by its own amplitude sum, so equal `height`
 *     knobs would draw normals for a sea 25% shallower than the geometry.
 */
void Pasture3DWaveProfile::_derive_fbm() {
	if (_fbm_authored || _fbm.is_null()) {
		return;
	}
	_ensure_built();
	const float ref_sigma_per_amp = 0.176f;
	const float k0 = (float)Math_TAU / MAX(_waves.get_length_max(), 0.01f);
	_deriving = true;
	for (int i = 0; i < 2; i++) {
		_fbm->set_knob(i, "seed", Math::deg_to_rad(_waves.get_direction_deg()));
		_fbm->set_knob(i, "frequency", k0);
		_fbm->set_knob(i, "speed", 2.f * std::sqrt(k0));
	}
	const float unit_sigma = _fbm->get_unit_sigma(Pasture3DWaterFBM::SET_VERTEX);
	const float height = unit_sigma > 1e-6f ? ref_sigma_per_amp * (float)_waves.get_amplitude_sum() / unit_sigma : 0.f;
	const float sum_v = _fbm->get_amplitude_sum(Pasture3DWaterFBM::SET_VERTEX);
	const float sum_f = _fbm->get_amplitude_sum(Pasture3DWaterFBM::SET_FRAGMENT);
	_fbm->set_knob(Pasture3DWaterFBM::SET_VERTEX, "height", height);
	_fbm->set_knob(Pasture3DWaterFBM::SET_FRAGMENT, "height", sum_v > 1e-6f ? height * sum_f / sum_v : height);
	_deriving = false;
}

void Pasture3DWaveProfile::set_fbm(const Ref<Pasture3DWaterFBM> &p_fbm) {
	if (_fbm == p_fbm) {
		return;
	}
	// As set_fft(): whatever arrives here was chosen.
	_fbm_authored = true;
	Callable cb = callable_mp(this, &Pasture3DWaveProfile::_on_fbm_changed);
	if (_fbm.is_valid() && _fbm->is_connected("changed", cb)) {
		_fbm->disconnect("changed", cb);
	}
	_fbm = p_fbm;
	if (_fbm.is_valid()) {
		_fbm->connect("changed", cb);
	}
	emit_changed();
}

void Pasture3DWaveProfile::set_fft(const Ref<Pasture3DWaterFFT> &p_fft) {
	if (_fft == p_fft) {
		return;
	}
	// Whatever arrives here was chosen: loaded from a scene, or assigned in the inspector.
	_fft_authored = true;
	Callable cb = callable_mp(this, &Pasture3DWaveProfile::_on_fft_changed);
	if (_fft.is_valid() && _fft->is_connected("changed", cb)) {
		_fft->disconnect("changed", cb);
	}
	_fft = p_fft;
	if (_fft.is_valid()) {
		_fft->set_loop_period((float)_waves.get_loop_period());
		_fft->connect("changed", cb);
	}
	emit_changed();
}

void Pasture3DWaveProfile::set_active_model(const int p_model) {
	const int model = CLAMP(p_model, (int)MODEL_GERSTNER, (int)MODEL_FBM);
	if (_active_model == model) {
		return;
	}
	_active_model = model;
	emit_changed();
}

void Pasture3DWaveProfile::set_profile_name(const StringName &p_name) {
	if (_profile_name == p_name) {
		return;
	}
	_profile_name = p_name;
	emit_changed();
}

void Pasture3DWaveProfile::set_wave_count(const int p_count) {
	const int before = _waves.get_count();
	_waves.set_count(p_count);
	if (_waves.get_count() == before) {
		return;
	}
	_derive_models();
	emit_changed();
}

void Pasture3DWaveProfile::set_direction_deg(const real_t p_deg) {
	const float before = _waves.get_direction_deg();
	_waves.set_direction_deg((float)p_deg);
	if (_waves.get_direction_deg() == before) {
		return;
	}
	_derive_models();
	emit_changed();
}

void Pasture3DWaveProfile::set_spread_deg(const real_t p_deg) {
	const float before = _waves.get_spread_deg();
	_waves.set_spread_deg((float)p_deg);
	if (_waves.get_spread_deg() == before) {
		return;
	}
	_derive_models();
	emit_changed();
}

void Pasture3DWaveProfile::set_amplitude(const real_t p_metres) {
	const float before = _waves.get_amplitude();
	_waves.set_amplitude((float)p_metres);
	if (_waves.get_amplitude() == before) {
		return;
	}
	_derive_models();
	emit_changed();
}

void Pasture3DWaveProfile::set_length_max(const real_t p_metres) {
	const float before = _waves.get_length_max();
	_waves.set_length_max((float)p_metres);
	if (_waves.get_length_max() == before) {
		return;
	}
	_derive_models();
	emit_changed();
}

void Pasture3DWaveProfile::set_steepness(const real_t p_steepness) {
	const float before = _waves.get_steepness();
	_waves.set_steepness((float)p_steepness);
	if (_waves.get_steepness() == before) {
		return;
	}
	_derive_models();
	emit_changed();
}

void Pasture3DWaveProfile::set_loop_period(const real_t p_seconds) {
	if (Math::is_equal_approx(_waves.get_loop_period(), (float)p_seconds)) {
		return;
	}
	_waves.set_loop_period((float)p_seconds);
	if (_fft.is_valid()) {
		// The FFT quantises its dispersion to the same period, for the same seamless wrap.
		_fft->set_loop_period((float)p_seconds);
	}
	emit_changed();
}

PackedVector4Array Pasture3DWaveProfile::get_shader_table() {
	_ensure_built();
	return _waves.get_shader_table();
}

real_t Pasture3DWaveProfile::get_amplitude_sum() {
	if (is_fft_active()) {
		return (real_t)_fft->get_displacement_bound();
	}
	if (is_fbm_active()) {
		return (real_t)_fbm->get_displacement_bound();
	}
	_ensure_built();
	return (real_t)_waves.get_amplitude_sum();
}

/**
 * Shortest wavelength actually in the table.
 *
 * Read off the built table rather than derived from length_max, because the series
 * does not run to a fixed ratio: WaterWaves floors it at MIN_WAVELENGTH for large
 * bodies but continues to length_max/2 for small ones (the pond case). Deriving it
 * would reproduce that rule in a second place and get it wrong the first time the
 * rule changed.
 *
 * Read off the Gerstner table EVEN WHEN THE FFT DRAWS. Its only consumer is mesh spacing, and the FFT
 * vertex stage picks its mip from whatever spacing it is given (water_eval_fft), so the spacing is a
 * cost knob there rather than a correctness one. Phase 2 first answered with a quarter of cascade 1;
 * that meshed lake_calm at 0.48 m instead of 1.27 m, the clipmap's reach shrank 2.6x and stopped
 * covering the lake's outline (WaterTwoLakesGate [B] 0.72). PASTURE3D_WATER_FFT_SPEC.md §4.
 */
real_t Pasture3DWaveProfile::get_min_wavelength() {
	_ensure_built();
	PackedVector4Array table = _waves.get_shader_table();
	real_t shortest = 0.f;
	for (int i = 0; i < table.size(); i++) {
		// Slots past the count are zero-amplitude padding and carry no wavelength
		// worth reporting; including them would return the padding's default.
		if (table[i].z <= 0.f) {
			continue;
		}
		if (shortest <= 0.f || (real_t)table[i].w < shortest) {
			shortest = (real_t)table[i].w;
		}
	}
	return shortest;
}

Vector3 Pasture3DWaveProfile::get_surface_point(const Vector2 &p_domain_xz, const real_t p_time) {
	_ensure_built();
	return _waves.get_position(p_domain_xz, (float)p_time);
}

real_t Pasture3DWaveProfile::get_height_at(const Vector2 &p_domain_xz, const real_t p_time) {
	_ensure_built();
	return (real_t)_waves.get_height(p_domain_xz, (float)p_time);
}

Vector3 Pasture3DWaveProfile::get_normal_at(const Vector2 &p_domain_xz, const real_t p_time) {
	_ensure_built();
	return _waves.get_normal(p_domain_xz, (float)p_time);
}

Vector2 Pasture3DWaveProfile::solve_domain(const Vector2 &p_target_xz, const real_t p_time) {
	_ensure_built();
	return _waves.solve_domain(p_target_xz, (float)p_time);
}

///////////////////////////
// Protected Functions
///////////////////////////

void Pasture3DWaveProfile::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_profile_name", "name"), &Pasture3DWaveProfile::set_profile_name);
	ClassDB::bind_method(D_METHOD("get_profile_name"), &Pasture3DWaveProfile::get_profile_name);
	ClassDB::bind_method(D_METHOD("set_wave_count", "count"), &Pasture3DWaveProfile::set_wave_count);
	ClassDB::bind_method(D_METHOD("get_wave_count"), &Pasture3DWaveProfile::get_wave_count);
	ClassDB::bind_method(D_METHOD("set_direction_deg", "degrees"), &Pasture3DWaveProfile::set_direction_deg);
	ClassDB::bind_method(D_METHOD("get_direction_deg"), &Pasture3DWaveProfile::get_direction_deg);
	ClassDB::bind_method(D_METHOD("set_spread_deg", "degrees"), &Pasture3DWaveProfile::set_spread_deg);
	ClassDB::bind_method(D_METHOD("get_spread_deg"), &Pasture3DWaveProfile::get_spread_deg);
	ClassDB::bind_method(D_METHOD("set_amplitude", "metres"), &Pasture3DWaveProfile::set_amplitude);
	ClassDB::bind_method(D_METHOD("get_amplitude"), &Pasture3DWaveProfile::get_amplitude);
	ClassDB::bind_method(D_METHOD("set_length_max", "metres"), &Pasture3DWaveProfile::set_length_max);
	ClassDB::bind_method(D_METHOD("get_length_max"), &Pasture3DWaveProfile::get_length_max);
	ClassDB::bind_method(D_METHOD("set_steepness", "steepness"), &Pasture3DWaveProfile::set_steepness);
	ClassDB::bind_method(D_METHOD("get_steepness"), &Pasture3DWaveProfile::get_steepness);
	ClassDB::bind_method(D_METHOD("set_fft", "fft"), &Pasture3DWaveProfile::set_fft);
	ClassDB::bind_method(D_METHOD("get_fft"), &Pasture3DWaveProfile::get_fft);
	ClassDB::bind_method(D_METHOD("set_fbm", "fbm"), &Pasture3DWaveProfile::set_fbm);
	ClassDB::bind_method(D_METHOD("get_fbm"), &Pasture3DWaveProfile::get_fbm);
	ClassDB::bind_method(D_METHOD("is_fft_authored"), &Pasture3DWaveProfile::is_fft_authored);
	ClassDB::bind_method(D_METHOD("is_fbm_authored"), &Pasture3DWaveProfile::is_fbm_authored);
	BIND_ENUM_CONSTANT(MODEL_GERSTNER);
	BIND_ENUM_CONSTANT(MODEL_FFT);
	BIND_ENUM_CONSTANT(MODEL_FBM);
	ClassDB::bind_method(D_METHOD("set_active_model", "model"), &Pasture3DWaveProfile::set_active_model);
	ClassDB::bind_method(D_METHOD("get_active_model"), &Pasture3DWaveProfile::get_active_model);
	ClassDB::bind_method(D_METHOD("is_fft_active"), &Pasture3DWaveProfile::is_fft_active);
	ClassDB::bind_method(D_METHOD("is_fbm_active"), &Pasture3DWaveProfile::is_fbm_active);
	ClassDB::bind_method(D_METHOD("set_loop_period", "seconds"), &Pasture3DWaveProfile::set_loop_period);
	ClassDB::bind_method(D_METHOD("get_loop_period"), &Pasture3DWaveProfile::get_loop_period);

	ClassDB::bind_method(D_METHOD("get_shader_table"), &Pasture3DWaveProfile::get_shader_table);
	ClassDB::bind_method(D_METHOD("get_amplitude_sum"), &Pasture3DWaveProfile::get_amplitude_sum);
	ClassDB::bind_method(D_METHOD("get_min_wavelength"), &Pasture3DWaveProfile::get_min_wavelength);

	ClassDB::bind_method(D_METHOD("get_surface_point", "domain_xz", "time"), &Pasture3DWaveProfile::get_surface_point);
	ClassDB::bind_method(D_METHOD("get_height_at", "domain_xz", "time"), &Pasture3DWaveProfile::get_height_at);
	ClassDB::bind_method(D_METHOD("get_normal_at", "domain_xz", "time"), &Pasture3DWaveProfile::get_normal_at);
	ClassDB::bind_method(D_METHOD("solve_domain", "target_xz", "time"), &Pasture3DWaveProfile::solve_domain);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "profile_name"), "set_profile_name", "get_profile_name");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "fft", PROPERTY_HINT_RESOURCE_TYPE, "Pasture3DWaterFFT"), "set_fft", "get_fft");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "fbm", PROPERTY_HINT_RESOURCE_TYPE, "Pasture3DWaterFBM"), "set_fbm", "get_fbm");
	ADD_GROUP("Gerstner", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "wave_count", PROPERTY_HINT_RANGE, "1,8,1"), "set_wave_count", "get_wave_count");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "direction_deg", PROPERTY_HINT_RANGE, "-360,360,0.5"), "set_direction_deg", "get_direction_deg");
	// 0..90, matching WaterWaves::set_spread_deg's clamp. The hint said 0..180, so the
	// top half of the slider moved and nothing happened -- the same defect
	// pasture_3d_ocean.cpp:set_mesh_size documents, with the range too wide instead of
	// too narrow. 90 is the real ceiling: the spread is applied as
	// direction +/- spread, so 90 already fans the series across a full half-turn.
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spread_deg", PROPERTY_HINT_RANGE, "0,90,0.5"), "set_spread_deg", "get_spread_deg");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "amplitude", PROPERTY_HINT_RANGE, "0,20,0.01,or_greater"), "set_amplitude", "get_amplitude");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "length_max", PROPERTY_HINT_RANGE, "1,1000,0.5,or_greater"), "set_length_max", "get_length_max");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "steepness", PROPERTY_HINT_RANGE, "0,0.6,0.01"), "set_steepness", "get_steepness");
}
