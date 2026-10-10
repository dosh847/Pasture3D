// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef PASTURE3D_WATER_FBM_CLASS_H
#define PASTURE3D_WATER_FBM_CLASS_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/packed_vector4_array.hpp>

#include "constants.h"

using namespace godot;

/**
 * The fBm wave fallback's knobs: GarrettGunnell/Water's "Euler wave" sum of exp(sin) octaves with domain
 * drag (Water.shader, USE_FBM). Spec: PASTURE3D_WATER_FFT_SPEC.md §3, §4.
 *
 * Pure data and closed-form statistics. The waves themselves are evaluated by water_waves.gdshaderinc
 * (water_eval_fbm, water_fbm_fragment); this class only packs the knobs for it and answers what the cull
 * bounds and the profile's height fit need to know without running the sum.
 *
 * Two octave SETS, as in the reference: VERTEX displaces the geometry with a few long octaves, FRAGMENT
 * draws the normals with many more. The reference evaluates both in world metres; here the domain is
 * scaled by each set's `frequency` first, so `frequency` is the first octave's wavenumber in rad/m and
 * every other knob (drag included) is relative to it. At frequency 1 rad/m that IS the reference; at any
 * other it keeps the reference's shape instead of letting the drag -- a displacement in absolute metres
 * there -- vanish on an ocean and dominate on a pond.
 *
 * Two deviations, both measured by WaterFBMGate:
 *   - The DC offset is removed. exp(sin) averages exp(-peak_offset) * I0(max_peak) per unit amplitude
 *     (0.47 at the defaults), so the reference's surface floats that fraction of `height` above its rest
 *     level. The mean is subtracted per octave, so a faded octave takes its mean with it.
 *   - Each octave's speed is quantised to the water clock's period, as the Gerstner and FFT phases are,
 *     so the wrap at water_time_period is seamless. Done in the shader against the live global.
 */
class Pasture3DWaterFBM : public Resource {
	GDCLASS(Pasture3DWaterFBM, Resource);
	CLASS_NAME();

public:
	enum OctaveSet {
		SET_VERTEX = 0,
		SET_FRAGMENT = 1,
	};
	static constexpr int MAX_OCTAVES = 64;
	static constexpr int KNOB_COUNT = 13;

	// One set's knobs, the reference's names. `octaves` is a count; the rest are floats.
	struct Knobs {
		float seed = 0.f; // radians: the first octave's direction (cos, sin) in XZ
		float seed_iter = 1253.2131f; // radians added per octave
		float frequency = 1.f; // rad/m, first octave
		float frequency_mult = 1.18f;
		float amplitude = 1.f; // relative; the output is normalised by the set's amplitude sum
		float amplitude_mult = 0.82f;
		float speed = 2.f; // rad/s, first octave
		float speed_ramp = 1.07f;
		float drag = 1.f;
		float height = 1.f; // metres the normalised sum is scaled to
		float max_peak = 1.f;
		float peak_offset = 1.f;
		float octaves = 8.f;
	};

private:
	Knobs _sets[2];

	static float *_knob_ptr(Knobs &p_k, const StringName &p_knob);

protected:
	static void _bind_methods();
	bool _set(const StringName &p_name, const Variant &p_value);
	bool _get(const StringName &p_name, Variant &r_ret) const;
	void _get_property_list(List<PropertyInfo> *p_list) const;

public:
	Pasture3DWaterFBM();
	~Pasture3DWaterFBM() {}

	void set_knob(const int p_set, const StringName &p_knob, const float p_value);
	float get_knob(const int p_set, const StringName &p_knob) const;
	int get_octaves(const int p_set) const;

	// The four vec4s the shader's _fbm_v0..3 / _fbm_f0..3 take:
	//   0 = (seed, seed_iter, frequency, frequency_mult)
	//   1 = (amplitude, amplitude_mult, speed, speed_ramp)
	//   2 = (drag, height, max_peak, peak_offset)
	//   3 = (amplitude_sum, unit_mean, octaves, 0)
	PackedVector4Array get_shader_pack(const int p_set) const;

	// Sum of the set's octave amplitudes: the reference's normaliser.
	float get_amplitude_sum(const int p_set) const;
	// Mean of exp(max_peak sin x - peak_offset) over a uniform phase: exp(-peak_offset) I0(max_peak).
	float get_unit_mean(const int p_set) const;
	// Height standard deviation per metre of `height`, treating the octaves as independent and ignoring
	// drag: exp(-o) sqrt(I0(2m) - I0(m)^2) sqrt(sum a^2) / sum a.
	float get_unit_sigma(const int p_set) const;
	// The vertex set's height standard deviation, metres.
	float get_height_sigma() const { return get_unit_sigma(SET_VERTEX) * _sets[SET_VERTEX].height; }
	// The vertex set's reach about its (zero) mean, metres: every octave at its crest, or every one at its
	// trough, whichever is further. A bound, not an estimate -- the fBm has no rare-crest tail to cover.
	float get_displacement_bound() const;

	// Modified Bessel function of the first kind, order 0. Public for the gate's CPU prediction.
	static double bessel_i0(const double p_x);
};

VARIANT_ENUM_CAST(Pasture3DWaterFBM::OctaveSet);

#endif // PASTURE3D_WATER_FBM_CLASS_H
