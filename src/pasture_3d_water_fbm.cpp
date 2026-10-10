// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/core/class_db.hpp>

#include <cmath>

#include "logger.h"
#include "pasture_3d_water_fbm.h"

///////////////////////////
// Public Functions
///////////////////////////

Pasture3DWaterFBM::Pasture3DWaterFBM() {
	// The reference's two sets differ only in octave count.
	_sets[SET_VERTEX].octaves = 8.f;
	_sets[SET_FRAGMENT].octaves = 40.f;
}

void Pasture3DWaterFBM::set_knob(const int p_set, const StringName &p_knob, const float p_value) {
	ERR_FAIL_INDEX(p_set, 2);
	float *v = _knob_ptr(_sets[p_set], p_knob);
	ERR_FAIL_NULL_MSG(v, vformat("Unknown fBm knob '%s'", String(p_knob)));
	float value = p_value;
	if (v == &_sets[p_set].octaves) {
		value = (float)CLAMP((int)std::lround(p_value), 1, MAX_OCTAVES);
	}
	if (*v == value) {
		return;
	}
	*v = value;
	emit_changed();
}

float Pasture3DWaterFBM::get_knob(const int p_set, const StringName &p_knob) const {
	ERR_FAIL_INDEX_V(p_set, 2, 0.f);
	float *v = _knob_ptr(const_cast<Knobs &>(_sets[p_set]), p_knob);
	ERR_FAIL_NULL_V_MSG(v, 0.f, vformat("Unknown fBm knob '%s'", String(p_knob)));
	return *v;
}

int Pasture3DWaterFBM::get_octaves(const int p_set) const {
	ERR_FAIL_INDEX_V(p_set, 2, 0);
	return (int)_sets[p_set].octaves;
}

/**
 * Line for line with water_fbm() and water_fbm_speed(). The pack is read back as float, so both sides start
 * from the same numbers; the shader's vec2 arithmetic is spelled out per component in the same order.
 */
Vector3 Pasture3DWaterFBM::evaluate(const int p_set, const Vector2 &p_domain_xz, const float p_time,
		const float p_period, const float p_spacing, const float p_min_samples) const {
	ERR_FAIL_INDEX_V(p_set, 2, Vector3());
	const PackedVector4Array pack = get_shader_pack(p_set);
	const float p0x = (float)pack[0].x, p0y = (float)pack[0].y, p0z = (float)pack[0].z, p0w = (float)pack[0].w;
	const float p1x = (float)pack[1].x, p1y = (float)pack[1].y, p1z = (float)pack[1].z, p1w = (float)pack[1].w;
	const float p2x = (float)pack[2].x, p2y = (float)pack[2].y, p2z = (float)pack[2].z, p2w = (float)pack[2].w;
	const float p3x = (float)pack[3].x, p3y = (float)pack[3].y, p3z = (float)pack[3].z;
	const bool drag_by_frequency = p_set == SET_FRAGMENT;
	constexpr float TAU = 6.283185307179586f;

	const float period = MAX(p_period, 1e-3f);
	float seed = p0x;
	const float k0 = MAX(p0z, 1e-6f);
	float f = 1.f;
	float a = p1x;
	float speed = p1z;
	float qx = (float)p_domain_xz.x * k0;
	float qz = (float)p_domain_xz.y * k0;
	float h = 0.f;
	float nx = 0.f;
	float nz = 0.f;
	const int octaves = (int)p3z;
	const float min_length = MAX(p_spacing, 1e-6f) * p_min_samples;
	for (int i = 0; i < octaves; i++) {
		const float w = CLAMP(TAU / (k0 * f * min_length) - 1.f, 0.f, 1.f);
		if (w <= 0.f && p0w >= 1.f) {
			break;
		}
		const float dx = std::cos(seed);
		const float dz = std::sin(seed);
		const float rate = std::round(speed * period / TAU) * (TAU / period);
		const float x = (dx * qx + dz * qz) * f + p_time * rate;
		const float wave = a * std::exp(p2z * std::sin(x) - p2w);
		const float dwave = p2z * wave * std::cos(x);
		h += w * (wave - a * p3y);
		nx += (w * f * dwave) * dx;
		nz += (w * f * dwave) * dz;
		const float drag = w * dwave * a * p2x * (drag_by_frequency ? f : 1.f);
		qx -= dx * drag;
		qz -= dz * drag;
		f *= p0w;
		a *= p1y;
		speed *= p1w;
		seed += p0y;
	}
	const float scale = p2y / MAX(p3x, 1e-6f);
	return Vector3(h * scale, nx * (scale * k0), nz * (scale * k0));
}

PackedVector4Array Pasture3DWaterFBM::get_shader_pack(const int p_set) const {
	PackedVector4Array pack;
	ERR_FAIL_INDEX_V(p_set, 2, pack);
	const Knobs &k = _sets[p_set];
	pack.push_back(Vector4(k.seed, k.seed_iter, k.frequency, k.frequency_mult));
	pack.push_back(Vector4(k.amplitude, k.amplitude_mult, k.speed, k.speed_ramp));
	pack.push_back(Vector4(k.drag, k.height, k.max_peak, k.peak_offset));
	pack.push_back(Vector4(get_amplitude_sum(p_set), get_unit_mean(p_set), k.octaves, 0.f));
	return pack;
}

float Pasture3DWaterFBM::get_amplitude_sum(const int p_set) const {
	ERR_FAIL_INDEX_V(p_set, 2, 0.f);
	const Knobs &k = _sets[p_set];
	double a = k.amplitude;
	double sum = 0.0;
	for (int i = 0; i < (int)k.octaves; i++) {
		sum += a;
		a *= k.amplitude_mult;
	}
	return (float)sum;
}

float Pasture3DWaterFBM::get_unit_mean(const int p_set) const {
	ERR_FAIL_INDEX_V(p_set, 2, 0.f);
	const Knobs &k = _sets[p_set];
	return (float)(std::exp(-(double)k.peak_offset) * bessel_i0(k.max_peak));
}

float Pasture3DWaterFBM::get_unit_sigma(const int p_set) const {
	ERR_FAIL_INDEX_V(p_set, 2, 0.f);
	const Knobs &k = _sets[p_set];
	const double m = k.max_peak;
	const double i0 = bessel_i0(m);
	const double var = MAX(bessel_i0(2.0 * m) - i0 * i0, 0.0);
	double a = k.amplitude;
	double sum = 0.0;
	double sum_sq = 0.0;
	for (int i = 0; i < (int)k.octaves; i++) {
		sum += a;
		sum_sq += a * a;
		a *= k.amplitude_mult;
	}
	if (std::abs(sum) < 1e-12) {
		return 0.f;
	}
	return (float)(std::exp(-(double)k.peak_offset) * std::sqrt(var) * std::sqrt(sum_sq) / std::abs(sum));
}

float Pasture3DWaterFBM::get_displacement_bound() const {
	const Knobs &k = _sets[SET_VERTEX];
	const double mean = get_unit_mean(SET_VERTEX);
	const double top = std::exp((double)k.max_peak - k.peak_offset) - mean;
	const double bottom = mean - std::exp(-(double)k.max_peak - k.peak_offset);
	return (float)(std::abs((double)k.height) * MAX(top, bottom));
}

// Power series; converges for every argument the knobs allow (max_peak is clamped by its hint, and the
// terms fall off as (x/2)^2k / (k!)^2).
double Pasture3DWaterFBM::bessel_i0(const double p_x) {
	const double q = 0.25 * p_x * p_x;
	double term = 1.0;
	double sum = 1.0;
	for (int k = 1; k < 64; k++) {
		term *= q / ((double)k * (double)k);
		sum += term;
		if (term < sum * 1e-17) {
			break;
		}
	}
	return sum;
}

///////////////////////////
// Protected Functions
///////////////////////////

float *Pasture3DWaterFBM::_knob_ptr(Knobs &p_k, const StringName &p_knob) {
	if (p_knob == StringName("seed")) {
		return &p_k.seed;
	} else if (p_knob == StringName("seed_iter")) {
		return &p_k.seed_iter;
	} else if (p_knob == StringName("frequency")) {
		return &p_k.frequency;
	} else if (p_knob == StringName("frequency_mult")) {
		return &p_k.frequency_mult;
	} else if (p_knob == StringName("amplitude")) {
		return &p_k.amplitude;
	} else if (p_knob == StringName("amplitude_mult")) {
		return &p_k.amplitude_mult;
	} else if (p_knob == StringName("speed")) {
		return &p_k.speed;
	} else if (p_knob == StringName("speed_ramp")) {
		return &p_k.speed_ramp;
	} else if (p_knob == StringName("drag")) {
		return &p_k.drag;
	} else if (p_knob == StringName("height")) {
		return &p_k.height;
	} else if (p_knob == StringName("max_peak")) {
		return &p_k.max_peak;
	} else if (p_knob == StringName("peak_offset")) {
		return &p_k.peak_offset;
	} else if (p_knob == StringName("octaves")) {
		return &p_k.octaves;
	}
	return nullptr;
}

// The two sets' knobs as "vertex/<knob>" and "fragment/<knob>", the FFT's spectrum pattern: one struct
// twice, and the knob names are already the API (set_knob).
static const char *SET_PREFIX[2] = { "vertex/", "fragment/" };
static const char *SET_KNOBS[Pasture3DWaterFBM::KNOB_COUNT] = { "octaves", "seed", "seed_iter", "frequency",
	"frequency_mult", "amplitude", "amplitude_mult", "speed", "speed_ramp", "drag", "height", "max_peak",
	"peak_offset" };
static const char *SET_HINTS[Pasture3DWaterFBM::KNOB_COUNT] = { "1,64,1", "-6.2832,6.2832,0.001,radians_as_degrees",
	"0,10000,0.0001,or_greater", "0.001,10,0.0001,or_greater,suffix:rad/m", "1,2,0.001", "0,10,0.001,or_greater",
	"0,1,0.001", "0,20,0.001,or_greater,suffix:rad/s", "0.5,2,0.001", "0,4,0.001", "0,50,0.01,or_greater,suffix:m",
	"0,4,0.001", "-4,4,0.001" };

static bool split_set_name(const StringName &p_name, int &r_set, StringName &r_knob) {
	String n = p_name;
	for (int i = 0; i < 2; i++) {
		if (n.begins_with(SET_PREFIX[i])) {
			r_set = i;
			r_knob = n.substr(String(SET_PREFIX[i]).length());
			return true;
		}
	}
	return false;
}

bool Pasture3DWaterFBM::_set(const StringName &p_name, const Variant &p_value) {
	int set;
	StringName knob;
	if (!split_set_name(p_name, set, knob) || !_knob_ptr(_sets[set], knob)) {
		return false;
	}
	set_knob(set, knob, (float)p_value);
	return true;
}

bool Pasture3DWaterFBM::_get(const StringName &p_name, Variant &r_ret) const {
	int set;
	StringName knob;
	if (!split_set_name(p_name, set, knob) || !_knob_ptr(const_cast<Knobs &>(_sets[set]), knob)) {
		return false;
	}
	if (knob == StringName("octaves")) {
		r_ret = get_octaves(set);
	} else {
		r_ret = get_knob(set, knob);
	}
	return true;
}

void Pasture3DWaterFBM::_get_property_list(List<PropertyInfo> *p_list) const {
	for (int i = 0; i < 2; i++) {
		for (int k = 0; k < KNOB_COUNT; k++) {
			p_list->push_back(PropertyInfo(k == 0 ? Variant::INT : Variant::FLOAT,
					String(SET_PREFIX[i]) + SET_KNOBS[k], PROPERTY_HINT_RANGE, SET_HINTS[k]));
		}
	}
}

void Pasture3DWaterFBM::_bind_methods() {
	BIND_ENUM_CONSTANT(SET_VERTEX);
	BIND_ENUM_CONSTANT(SET_FRAGMENT);

	ClassDB::bind_method(D_METHOD("set_knob", "set", "knob", "value"), &Pasture3DWaterFBM::set_knob);
	ClassDB::bind_method(D_METHOD("get_knob", "set", "knob"), &Pasture3DWaterFBM::get_knob);
	ClassDB::bind_method(D_METHOD("get_octaves", "set"), &Pasture3DWaterFBM::get_octaves);
	ClassDB::bind_method(D_METHOD("get_shader_pack", "set"), &Pasture3DWaterFBM::get_shader_pack);
	ClassDB::bind_method(D_METHOD("evaluate", "set", "domain_xz", "time", "period", "spacing", "min_samples"),
			&Pasture3DWaterFBM::evaluate, DEFVAL(0.f), DEFVAL(4.f));
	ClassDB::bind_method(D_METHOD("get_amplitude_sum", "set"), &Pasture3DWaterFBM::get_amplitude_sum);
	ClassDB::bind_method(D_METHOD("get_unit_mean", "set"), &Pasture3DWaterFBM::get_unit_mean);
	ClassDB::bind_method(D_METHOD("get_unit_sigma", "set"), &Pasture3DWaterFBM::get_unit_sigma);
	ClassDB::bind_method(D_METHOD("get_height_sigma"), &Pasture3DWaterFBM::get_height_sigma);
	ClassDB::bind_method(D_METHOD("get_displacement_bound"), &Pasture3DWaterFBM::get_displacement_bound);
	ClassDB::bind_static_method("Pasture3DWaterFBM", D_METHOD("bessel_i0", "x"), &Pasture3DWaterFBM::bessel_i0);
}
