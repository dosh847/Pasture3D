// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/core/class_db.hpp>

#include <cmath>

#include "logger.h"
#include "pasture_3d_wave_profile.h"

///////////////////////////
// Public Functions
///////////////////////////

// Every setter emits changed() WHEN IT CHANGES SOMETHING. Pasture3DPoolManager listens for
// it and re-uploads into the materials it has cached for this profile -- which is what
// makes dragging a knob in the inspector move ten ponds at once, and is the only reason
// the manager does not have to poll.
//
// The guard is not a micro-optimisation. One emission reaches _on_profile_changed(), which
// re-uploads into EVERY cached material and then emits profiles_changed, which makes every
// Pasture3DOcean rebuild its runtime material and force an AABB update.

Pasture3DWaveProfile::Pasture3DWaveProfile() {
	Ref<Pasture3DWaterFFT> fft;
	fft.instantiate();
	set_fft(fft);
	Ref<Pasture3DWaterFBM> fbm;
	fbm.instantiate();
	set_fbm(fbm);
	// The defaults are not authored ones: a scene that stores only legacy keys re-fits them on load.
	_fft_authored = false;
	_fbm_authored = false;
	// A new profile is the reference's sea (PASTURE3D_WATER_REFERENCE_SPEC.md §5): the FFT's defaults
	// exactly, the fBm fitted to them, min_wavelength read off them.
	_fit(fft->get_spectrum_knob(0, "direction_deg"), REF_LENGTH, -1.f, false);
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
 * Fits the FFT and the fBm to a direction, a size and a height.
 *
 * FFT. The simulation's defaults are the reference's scene (PASTURE3D_WATER_REFERENCE_SPEC.md §2). This
 * keeps that sea's SHAPE -- all eight spectra, the cascade roles, the foam -- and rescales it:
 *
 *   SIZE by r = length_max / REF_LENGTH, by Froude similarity: every length by r, every speed by sqrt(r).
 *   Cascade lengths, tiles (a tile of 0 stays 0), depth and each spectrum's fetch and short_waves_fade
 *   scale by r; wind by sqrt(r). The JONSWAP alpha depends on g F / U^2 and the peak wavelength on U F / g
 *   to the 0.66 (0.99 r after the 1.5 power), the spread on omega / omega_peak and TMA on omega sqrt(d / g),
 *   so the scaled sea is the reference's sea at r of its size: heights scale by r too, slopes not at all.
 *
 *   DIRECTION. Every spectrum turns by p_direction_deg minus the reference's first spectrum's, so the
 *   displacing cascade's first spectrum runs along p_direction_deg and the rest keep their angles to it.
 *
 *   HEIGHT to p_sigma, through `scale` (variance, so squared), which moves all eight spectra together. A
 *   negative p_sigma leaves the scaled reference's own height.
 *
 * min_wavelength is then read off the fitted FFT: the shortest wave that leaves under HEIGHT_TOLERANCE of
 * height sigma to the normals. Height, not a share of the variance, because what the geometry misses is
 * metres: a share would mesh a 2 cm lake's waves as finely as an ocean's.
 *
 * fBm. The reference's knobs are its look; this keeps all of them except the four that say WHERE and HOW BIG:
 *
 *   DIRECTION. The first octave runs along p_direction_deg (`seed` is that angle in radians).
 *   SIZE. `frequency` is 2 pi / length_max, so the first octave is the longest wave. The rest of the
 *     series is relative to it (Pasture3DWaterFBM's class comment), so the shape scales with it.
 *   SPEED. The reference runs 2 rad/s at 1 rad/m, which is 0.64 of deep-water dispersion sqrt(g k). Kept as
 *     that fraction: speed = 2 sqrt(k), so a pond's ripples do not crawl and an ocean's swell does not race.
 *   HEIGHT. p_sigma, from the closed-form sigma of the vertex set. The fragment set is then scaled so its
 *     first octaves are the SAME metres as the vertex set's -- the reference normalises each set by its own
 *     amplitude sum, so equal `height` knobs would draw normals for a sea 25% shallower than the geometry.
 */
void Pasture3DWaveProfile::_fit(const real_t p_direction_deg, const real_t p_length_max, const real_t p_sigma,
		const bool p_force) {
	const float length_max = MAX((float)p_length_max, 0.01f);
	const float r = CLAMP(length_max / (float)REF_LENGTH, 0.01f, 20.f);
	// The default sea's knobs, read from a default instance so they cannot drift from it.
	constexpr int n = Pasture3DWaterFFT::SPECTRA;
	Pasture3DWaterFFT *ref = memnew(Pasture3DWaterFFT);
	const Vector4 ref_lengths = ref->get_cascade_lengths();
	const Vector4 ref_tiles = ref->get_cascade_tiles();
	const float ref_depth = ref->get_depth();
	const float ref_sigma = ref->get_height_sigma();
	float ref_knobs[n][5];
	static const char *scaled[5] = { "fetch", "short_waves_fade", "wind_speed", "direction_deg", "scale" };
	for (int i = 0; i < n; i++) {
		for (int j = 0; j < 5; j++) {
			ref_knobs[i][j] = ref->get_spectrum_knob(i, scaled[j]);
		}
	}
	memdelete(ref);
	const float turn = (float)p_direction_deg - ref_knobs[0][3];
	const float target = MAX((float)p_sigma, 0.f);
	_deriving = true;
	if (_fft.is_valid() && (p_force || !_fft_authored)) {
		_fft->set_cascade_lengths(ref_lengths * r);
		_fft->set_cascade_tiles(ref_tiles * r);
		_fft->set_depth(ref_depth * r);
		const float speed = std::sqrt(r);
		for (int i = 0; i < n; i++) {
			_fft->set_spectrum_knob(i, "fetch", ref_knobs[i][0] * r);
			_fft->set_spectrum_knob(i, "short_waves_fade", ref_knobs[i][1] * r);
			_fft->set_spectrum_knob(i, "wind_speed", ref_knobs[i][2] * speed);
			_fft->set_spectrum_knob(i, "direction_deg", ref_knobs[i][3] + turn);
			_fft->set_spectrum_knob(i, "scale", ref_knobs[i][4]);
		}
		if (p_sigma >= 0.f) {
			const float sigma = _fft->get_height_sigma();
			const float gain = sigma > 1e-6f ? (target / sigma) * (target / sigma) : 0.f;
			for (int i = 0; i < n; i++) {
				_fft->set_spectrum_knob(i, "scale", ref_knobs[i][4] * gain);
			}
		}
		// The variance left below min_wavelength is (1 - fraction) sigma^2; keep it under the tolerance^2.
		const float sigma = _fft->get_height_sigma();
		const float fraction = sigma > HEIGHT_TOLERANCE ? 1.f - (HEIGHT_TOLERANCE / sigma) * (HEIGHT_TOLERANCE / sigma) : 0.f;
		const float wavelength = _fft->get_variance_wavelength(fraction);
		if (wavelength > 0.f) {
			_min_wavelength = MAX((real_t)wavelength, (real_t)0.1f);
		}
	}
	if (_fbm.is_valid() && (p_force || !_fbm_authored)) {
		const float k0 = (float)Math_TAU / length_max;
		for (int i = 0; i < 2; i++) {
			_fbm->set_knob(i, "seed", Math::deg_to_rad((float)p_direction_deg));
			_fbm->set_knob(i, "frequency", k0);
			_fbm->set_knob(i, "speed", 2.f * std::sqrt(k0));
		}
		// Without a height, the fBm matches the FFT as it now stands, so the two models draw one sea.
		const float fbm_target = p_sigma >= 0.f ? target : (_fft.is_valid() ? _fft->get_height_sigma() : ref_sigma * r);
		const float unit_sigma = _fbm->get_unit_sigma(Pasture3DWaterFBM::SET_VERTEX);
		const float height = unit_sigma > 1e-6f ? fbm_target / unit_sigma : 0.f;
		const float sum_v = _fbm->get_amplitude_sum(Pasture3DWaterFBM::SET_VERTEX);
		const float sum_f = _fbm->get_amplitude_sum(Pasture3DWaterFBM::SET_FRAGMENT);
		_fbm->set_knob(Pasture3DWaterFBM::SET_VERTEX, "height", height);
		_fbm->set_knob(Pasture3DWaterFBM::SET_FRAGMENT, "height", sum_v > 1e-6f ? height * sum_f / sum_v : height);
	}
	_deriving = false;
}

void Pasture3DWaveProfile::_apply_legacy() {
	float sum = 0.f;
	float shortest = 0.f;
	legacy_series(_legacy.count, _legacy.amplitude, _legacy.length_max, LEGACY_LOOP_PERIOD, sum, shortest);
	// min_wavelength follows the FFT the fit draws, not the retired table's shortest wave.
	_fit(_legacy.direction_deg, MAX(_legacy.length_max, LEGACY_MIN_WAVELENGTH), LEGACY_SIGMA_PER_AMP * sum, false);
	emit_changed();
}

/**
 * The retired WaterWaves::update(), reduced to the two numbers anything still needs.
 *
 * Wavelengths form a geometric series from length_max down to MIN(10 m, length_max / 2), each quantised
 * to a whole number of cycles in the loop period, with amplitude proportional to wavelength. In float,
 * in the old order, so a migrated profile fits to the same sum its Gerstner table had.
 */
void Pasture3DWaveProfile::legacy_series(const int p_count, const float p_amplitude, const float p_length_max,
		const float p_loop_period, float &r_amplitude_sum, float &r_shortest) {
	const float tau = 6.283185307179586f;
	const float gravity = 9.81f;
	const int count = CLAMP(p_count, 1, 8);
	const float amplitude = MAX(p_amplitude, 0.f);
	const float length_max = MAX(p_length_max, LEGACY_MIN_WAVELENGTH);
	const float length_min = MIN(LEGACY_MIN_WAVELENGTH, length_max * 0.5f);
	const float ratio = (count > 1) ? std::pow(length_min / length_max, 1.0f / float(count - 1)) : 1.0f;
	r_amplitude_sum = 0.f;
	r_shortest = 0.f;
	for (int i = 0; i < count; i++) {
		float wavelength = length_max * std::pow(ratio, float(i));
		if (p_loop_period > 0.f) {
			const float w = tau / wavelength;
			const float omega = std::sqrt(gravity * w);
			const float cycles = MAX(std::round(omega * p_loop_period / tau), 1.0f);
			const float omega_q = tau * cycles / p_loop_period;
			const float w_q = omega_q * omega_q / gravity;
			wavelength = tau / w_q;
		}
		r_amplitude_sum += amplitude * (wavelength / length_max);
		if (r_shortest <= 0.f || wavelength < r_shortest) {
			r_shortest = wavelength;
		}
	}
}

bool Pasture3DWaveProfile::migrate_legacy_key(const StringName &p_name, const Variant &p_value) {
	if (p_name == StringName("wave_count")) {
		_legacy.count = CLAMP((int)p_value, 1, 8);
	} else if (p_name == StringName("direction_deg")) {
		_legacy.direction_deg = (float)p_value;
	} else if (p_name == StringName("amplitude")) {
		_legacy.amplitude = MAX((float)p_value, 0.f);
	} else if (p_name == StringName("length_max")) {
		_legacy.length_max = MAX((float)p_value, LEGACY_MIN_WAVELENGTH);
	} else if (p_name == StringName("spread_deg") || p_name == StringName("steepness")) {
		return true; // Gerstner-only: neither model has an equivalent
	} else {
		return false;
	}
	_apply_legacy();
	return true;
}

void Pasture3DWaveProfile::fit_sea(const real_t p_direction_deg, const real_t p_length_max, const real_t p_sigma) {
	_fit(p_direction_deg, p_length_max, MAX(p_sigma, (real_t)0.f), true);
	_fft_authored = _fft.is_valid();
	_fbm_authored = _fbm.is_valid();
	emit_changed();
}

void Pasture3DWaveProfile::fit_reference_sea(const real_t p_direction_deg, const real_t p_length_max) {
	_fit(p_direction_deg, p_length_max, -1.f, true);
	_fft_authored = _fft.is_valid();
	_fbm_authored = _fbm.is_valid();
	emit_changed();
}

void Pasture3DWaveProfile::set_min_wavelength(const real_t p_metres) {
	const real_t metres = MAX(p_metres, (real_t)0.1f);
	if (_min_wavelength == metres) {
		return;
	}
	_min_wavelength = metres;
	emit_changed();
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
		_fft->set_loop_period((float)_loop_period);
		_fft->connect("changed", cb);
	}
	emit_changed();
}

void Pasture3DWaveProfile::set_active_model(const int p_model) {
	const int model = p_model == MODEL_FFT ? MODEL_FFT : MODEL_FBM;
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

void Pasture3DWaveProfile::set_loop_period(const real_t p_seconds) {
	const real_t seconds = MAX(p_seconds, (real_t)0.f);
	if (Math::is_equal_approx(_loop_period, seconds)) {
		return;
	}
	_loop_period = seconds;
	if (_fft.is_valid()) {
		// The FFT quantises its dispersion to the period, so the clock's wrap is seamless.
		_fft->set_loop_period((float)seconds);
	}
	emit_changed();
}

real_t Pasture3DWaveProfile::get_amplitude_sum() {
	if (is_fft_active()) {
		return (real_t)_fft->get_displacement_bound();
	}
	if (is_fbm_active()) {
		return (real_t)_fbm->get_displacement_bound();
	}
	return 0.f;
}

real_t Pasture3DWaveProfile::get_length_max() const {
	if (is_fft_active()) {
		const Vector4 l = _fft->get_cascade_lengths();
		return (real_t)MAX(MAX(l.x, l.y), MAX(l.z, l.w)) * (REF_LENGTH / REF_TILE);
	}
	if (is_fbm_active()) {
		const float k0 = _fbm->get_knob(Pasture3DWaterFBM::SET_VERTEX, "frequency");
		return k0 > 1e-6f ? (real_t)Math_TAU / k0 : 0.f;
	}
	return 0.f;
}

Vector3 Pasture3DWaveProfile::_fft_point(const Pasture3DWaterFFT::CpuSurface &p_surface, const Vector2 &p_domain_xz) {
	const Vector3 d = p_surface.sample(p_domain_xz);
	return Vector3(p_domain_xz.x + d.x, d.y, p_domain_xz.y + d.z);
}

Pasture3DWaterFFT::CpuSurface Pasture3DWaveProfile::_fft_surface() {
	_fft->request_cpu_surface();
	return _fft->get_cpu_surface();
}

Vector3 Pasture3DWaveProfile::_fbm_vertex(const Vector2 &p_domain_xz, const real_t p_time) const {
	// The clock's period is the one the manager pushed in (set_loop_period), which is water_time_period.
	return _fbm->evaluate(Pasture3DWaterFBM::SET_VERTEX, p_domain_xz, (float)p_time, (float)get_loop_period());
}

Vector3 Pasture3DWaveProfile::get_surface_point(const Vector2 &p_domain_xz, const real_t p_time) {
	if (is_fft_active()) {
		return _fft_point(_fft_surface(), p_domain_xz);
	}
	if (is_fbm_active()) {
		return Vector3(p_domain_xz.x, _fbm_vertex(p_domain_xz, p_time).x, p_domain_xz.y);
	}
	return Vector3(p_domain_xz.x, 0.f, p_domain_xz.y);
}

real_t Pasture3DWaveProfile::get_height_at(const Vector2 &p_domain_xz, const real_t p_time) {
	if (is_fft_active()) {
		return _fft_surface().sample(p_domain_xz).y;
	}
	if (is_fbm_active()) {
		return _fbm_vertex(p_domain_xz, p_time).x;
	}
	return 0.f;
}

Vector3 Pasture3DWaveProfile::get_normal_at(const Vector2 &p_domain_xz, const real_t p_time) {
	if (is_fft_active()) {
		const Pasture3DWaterFFT::CpuSurface surface = _fft_surface();
		const Vector2 hx(FFT_NORMAL_STEP, 0.f);
		const Vector2 hz(0.f, FFT_NORMAL_STEP);
		const Vector3 tx = _fft_point(surface, p_domain_xz + hx) - _fft_point(surface, p_domain_xz - hx);
		const Vector3 tz = _fft_point(surface, p_domain_xz + hz) - _fft_point(surface, p_domain_xz - hz);
		const Vector3 n = tz.cross(tx);
		return n.length_squared() > 0.f ? n.normalized() : Vector3(0.f, 1.f, 0.f);
	}
	if (is_fbm_active()) {
		const Vector3 s = _fbm_vertex(p_domain_xz, p_time);
		return Vector3(-s.y, 1.f, -s.z).normalized();
	}
	return Vector3(0.f, 1.f, 0.f);
}

Vector2 Pasture3DWaveProfile::solve_domain(const Vector2 &p_target_xz, const real_t p_time) {
	if (is_fft_active()) {
		// Fixed-point inverse of the horizontal displacement, u += target - P(u).xz. One copy of the surface
		// for every iteration, so the solve cannot straddle two frames.
		const Pasture3DWaterFFT::CpuSurface surface = _fft_surface();
		Vector2 u = p_target_xz;
		for (int k = 0; k < SOLVE_ITERATIONS; k++) {
			const Vector3 p = _fft_point(surface, u);
			const Vector2 step(p_target_xz.x - p.x, p_target_xz.y - p.z);
			u += step;
			if (step.length_squared() <= SOLVE_EPSILON * SOLVE_EPSILON) {
				break;
			}
		}
		return u;
	}
	return p_target_xz; // the fBm moves the surface vertically only, and a flat one not at all
}

///////////////////////////
// Protected Functions
///////////////////////////

bool Pasture3DWaveProfile::_set(const StringName &p_name, const Variant &p_value) {
	return migrate_legacy_key(p_name, p_value);
}

bool Pasture3DWaveProfile::is_legacy_copy(const int p_count, const real_t p_direction_deg, const real_t p_amplitude,
		const real_t p_length_max) const {
	return !_fft_authored && !_fbm_authored && _legacy.count == p_count &&
			Math::is_equal_approx(_legacy.direction_deg, (float)p_direction_deg) &&
			Math::is_equal_approx(_legacy.amplitude, (float)p_amplitude) &&
			Math::is_equal_approx(_legacy.length_max, MAX((float)p_length_max, LEGACY_MIN_WAVELENGTH));
}

void Pasture3DWaveProfile::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_profile_name", "name"), &Pasture3DWaveProfile::set_profile_name);
	ClassDB::bind_method(D_METHOD("get_profile_name"), &Pasture3DWaveProfile::get_profile_name);
	ClassDB::bind_method(D_METHOD("set_fft", "fft"), &Pasture3DWaveProfile::set_fft);
	ClassDB::bind_method(D_METHOD("get_fft"), &Pasture3DWaveProfile::get_fft);
	ClassDB::bind_method(D_METHOD("set_fbm", "fbm"), &Pasture3DWaveProfile::set_fbm);
	ClassDB::bind_method(D_METHOD("get_fbm"), &Pasture3DWaveProfile::get_fbm);
	ClassDB::bind_method(D_METHOD("is_fft_authored"), &Pasture3DWaveProfile::is_fft_authored);
	ClassDB::bind_method(D_METHOD("is_fbm_authored"), &Pasture3DWaveProfile::is_fbm_authored);
	ClassDB::bind_method(D_METHOD("is_legacy_copy", "count", "direction_deg", "amplitude", "length_max"),
			&Pasture3DWaveProfile::is_legacy_copy);
	ClassDB::bind_method(D_METHOD("set_min_wavelength", "metres"), &Pasture3DWaveProfile::set_min_wavelength);
	ClassDB::bind_method(D_METHOD("get_min_wavelength"), &Pasture3DWaveProfile::get_min_wavelength);
	ClassDB::bind_method(D_METHOD("fit_sea", "direction_deg", "length_max", "sigma"), &Pasture3DWaveProfile::fit_sea);
	ClassDB::bind_method(D_METHOD("fit_reference_sea", "direction_deg", "length_max"), &Pasture3DWaveProfile::fit_reference_sea);
	BIND_ENUM_CONSTANT(MODEL_FFT);
	BIND_ENUM_CONSTANT(MODEL_FBM);
	ClassDB::bind_method(D_METHOD("set_active_model", "model"), &Pasture3DWaveProfile::set_active_model);
	ClassDB::bind_method(D_METHOD("get_active_model"), &Pasture3DWaveProfile::get_active_model);
	ClassDB::bind_method(D_METHOD("is_fft_active"), &Pasture3DWaveProfile::is_fft_active);
	ClassDB::bind_method(D_METHOD("is_fbm_active"), &Pasture3DWaveProfile::is_fbm_active);
	ClassDB::bind_method(D_METHOD("set_loop_period", "seconds"), &Pasture3DWaveProfile::set_loop_period);
	ClassDB::bind_method(D_METHOD("get_loop_period"), &Pasture3DWaveProfile::get_loop_period);

	ClassDB::bind_method(D_METHOD("get_amplitude_sum"), &Pasture3DWaveProfile::get_amplitude_sum);
	ClassDB::bind_method(D_METHOD("get_length_max"), &Pasture3DWaveProfile::get_length_max);

	ClassDB::bind_method(D_METHOD("get_surface_point", "domain_xz", "time"), &Pasture3DWaveProfile::get_surface_point);
	ClassDB::bind_method(D_METHOD("get_height_at", "domain_xz", "time"), &Pasture3DWaveProfile::get_height_at);
	ClassDB::bind_method(D_METHOD("get_normal_at", "domain_xz", "time"), &Pasture3DWaveProfile::get_normal_at);
	ClassDB::bind_method(D_METHOD("solve_domain", "target_xz", "time"), &Pasture3DWaveProfile::solve_domain);

	ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "profile_name"), "set_profile_name", "get_profile_name");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "fft", PROPERTY_HINT_RESOURCE_TYPE, "Pasture3DWaterFFT"), "set_fft", "get_fft");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "fbm", PROPERTY_HINT_RESOURCE_TYPE, "Pasture3DWaterFBM"), "set_fbm", "get_fbm");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "min_wavelength", PROPERTY_HINT_RANGE, "0.1,100,0.01,or_greater,suffix:m"), "set_min_wavelength", "get_min_wavelength");
}
