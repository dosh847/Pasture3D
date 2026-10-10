// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/rd_shader_source.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <cmath>
#include <cstring>

#include "logger.h"
#include "pasture_3d_water_fft.h"

static const char *WATER_FFT_GLSL =
#include "shaders/water_fft.glsl"
		;

static const char *KERNEL_DEFINES[] = {
	"KERNEL_INIT",
	"KERNEL_PACK",
	"KERNEL_UPDATE",
	"KERNEL_FFT_H",
	"KERNEL_FFT_V",
	"KERNEL_ASSEMBLE",
	"KERNEL_DOWNSAMPLE",
};

// Floats in the kernel's Params block (std430): 2 spectra x 8, three vec4s, then 12 scalars.
static constexpr int PARAM_FLOATS = 40;

///////////////////////////
// Private Functions
///////////////////////////

bool Pasture3DWaterFFT::_ensure_device() {
	if (_rd) {
		return true;
	}
	if (_init_failed) {
		return false;
	}
	_rd = RS->get_rendering_device();
	if (!_rd) {
		_init_failed = true;
		LOG(WARN, "No RenderingDevice (Compatibility renderer or headless); the FFT ocean cannot run");
		return false;
	}
	return true;
}

bool Pasture3DWaterFFT::_compile_kernels() {
	int log_n = 0;
	while ((1 << log_n) < _resolution) {
		log_n++;
	}
	for (int k = 0; k < K_COUNT; k++) {
		String header = vformat("#version 450\n#define N %d\n#define LOG_N %d\n#define %s\n", _resolution, log_n,
				KERNEL_DEFINES[k]);
		Ref<RDShaderSource> src;
		src.instantiate();
		src->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, header + String(WATER_FFT_GLSL));
		Ref<RDShaderSPIRV> spirv = _rd->shader_compile_spirv_from_source(src);
		if (spirv.is_null() || !spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE).is_empty()) {
			LOG(ERROR, "Kernel ", KERNEL_DEFINES[k], " failed to compile: ",
					spirv.is_null() ? String("no SPIR-V") : spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE));
			return false;
		}
		_shaders[k] = _rd->shader_create_from_spirv(spirv, vformat("Pasture3DWaterFFT %s", KERNEL_DEFINES[k]));
		if (!_shaders[k].is_valid()) {
			return false;
		}
		_pipelines[k] = _rd->compute_pipeline_create(_shaders[k]);
		if (!_pipelines[k].is_valid()) {
			return false;
		}
	}
	return true;
}

static RID make_array_texture(RenderingDevice *p_rd, const int p_n, const int p_layers, const int p_mips,
		const RenderingDevice::DataFormat p_format) {
	Ref<RDTextureFormat> fmt;
	fmt.instantiate();
	fmt->set_texture_type(RenderingDevice::TEXTURE_TYPE_2D_ARRAY);
	fmt->set_format(p_format);
	fmt->set_width(p_n);
	fmt->set_height(p_n);
	fmt->set_array_layers(p_layers);
	fmt->set_mipmaps(p_mips);
	fmt->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_STORAGE_BIT |
			RenderingDevice::TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice::TEXTURE_USAGE_CAN_COPY_TO_BIT);
	Ref<RDTextureView> view;
	view.instantiate();
	RID tex = p_rd->texture_create(fmt, view);
	if (tex.is_valid()) {
		// Fresh texture memory is undefined, and the foam channel is read before it is first written.
		p_rd->texture_clear(tex, Color(0.f, 0.f, 0.f, 0.f), 0, p_mips, 0, p_layers);
	}
	return tex;
}

static Ref<RDUniform> image_uniform(const int p_binding, const RID &p_rid) {
	Ref<RDUniform> u;
	u.instantiate();
	u->set_uniform_type(RenderingDevice::UNIFORM_TYPE_IMAGE);
	u->set_binding(p_binding);
	u->add_id(p_rid);
	return u;
}

// An image2D[CASCADES] binding: the four cascade views of one mip level.
static Ref<RDUniform> cascade_uniform(const int p_binding, const Vector<RID> &p_views, const int p_mip) {
	Ref<RDUniform> u;
	u.instantiate();
	u->set_uniform_type(RenderingDevice::UNIFORM_TYPE_IMAGE);
	u->set_binding(p_binding);
	for (int c = 0; c < Pasture3DWaterFFT::CASCADES; c++) {
		u->add_id(p_views[p_mip * Pasture3DWaterFFT::CASCADES + c]);
	}
	return u;
}

RID Pasture3DWaterFFT::_make_set(const Kernel p_kernel, const TypedArray<RDUniform> &p_uniforms) {
	return _rd->uniform_set_create(p_uniforms, _shaders[p_kernel], 0);
}

bool Pasture3DWaterFFT::_build_resources() {
	const int n = _resolution;
	_mip_count = 1;
	while ((n >> _mip_count) >= 1) {
		_mip_count++;
	}
	_mip_count--; // n=256 -> 9 levels, 256 down to 1

	_params_buffer = _rd->storage_buffer_create(PARAM_FLOATS * 4);
	_initial_tex = make_array_texture(_rd, n, CASCADES, 1, RenderingDevice::DATA_FORMAT_R32G32B32A32_SFLOAT);
	_spectrum_tex = make_array_texture(_rd, n, CASCADES * 2, 1, RenderingDevice::DATA_FORMAT_R32G32B32A32_SFLOAT);
	_disp_tex = make_array_texture(_rd, n, CASCADES, _mip_count, RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT);
	_slope_tex = make_array_texture(_rd, n, CASCADES, _mip_count, RenderingDevice::DATA_FORMAT_R16G16B16A16_SFLOAT);
	if (!_params_buffer.is_valid() || !_initial_tex.is_valid() || !_spectrum_tex.is_valid() || !_disp_tex.is_valid() ||
			!_slope_tex.is_valid()) {
		LOG(ERROR, "Could not allocate FFT textures at resolution ", n);
		return false;
	}

	// Storage bindings get one 2D view per (mip, cascade). A storage image writes its view's base level,
	// so the downsample needs a view per level, and binding the whole chain for mip 0 is not portable.
	Ref<RDTextureView> view;
	view.instantiate();
	for (int m = 0; m < _mip_count; m++) {
		for (int c = 0; c < CASCADES; c++) {
			_disp_views.push_back(_rd->texture_create_shared_from_slice(view, _disp_tex, c, m, 1,
					RenderingDevice::TEXTURE_SLICE_2D));
			_slope_views.push_back(_rd->texture_create_shared_from_slice(view, _slope_tex, c, m, 1,
					RenderingDevice::TEXTURE_SLICE_2D));
		}
	}

	Ref<RDUniform> params;
	params.instantiate();
	params->set_uniform_type(RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER);
	params->set_binding(0);
	params->add_id(_params_buffer);
	Ref<RDUniform> initial = image_uniform(1, _initial_tex);
	Ref<RDUniform> spectrum = image_uniform(2, _spectrum_tex);

	TypedArray<RDUniform> u;
	u = TypedArray<RDUniform>();
	u.push_back(params);
	u.push_back(initial);
	_sets[K_INIT] = _make_set(K_INIT, u);

	u = TypedArray<RDUniform>();
	u.push_back(initial);
	_sets[K_PACK] = _make_set(K_PACK, u);

	u = TypedArray<RDUniform>();
	u.push_back(params);
	u.push_back(initial);
	u.push_back(spectrum);
	_sets[K_UPDATE] = _make_set(K_UPDATE, u);

	u = TypedArray<RDUniform>();
	u.push_back(spectrum);
	_sets[K_FFT_H] = _make_set(K_FFT_H, u);
	_sets[K_FFT_V] = _make_set(K_FFT_V, u);

	u = TypedArray<RDUniform>();
	u.push_back(params);
	u.push_back(spectrum);
	u.push_back(cascade_uniform(3, _disp_views, 0));
	u.push_back(cascade_uniform(4, _slope_views, 0));
	_sets[K_ASSEMBLE] = _make_set(K_ASSEMBLE, u);

	for (int m = 1; m < _mip_count; m++) {
		u = TypedArray<RDUniform>();
		u.push_back(cascade_uniform(5, _disp_views, m - 1));
		u.push_back(cascade_uniform(6, _disp_views, m));
		u.push_back(cascade_uniform(7, _slope_views, m - 1));
		u.push_back(cascade_uniform(8, _slope_views, m));
		_downsample_sets.push_back(_make_set(K_DOWNSAMPLE, u));
	}
	for (int k = 0; k < K_DOWNSAMPLE; k++) {
		if (!_sets[k].is_valid()) {
			LOG(ERROR, "Could not create the uniform set for ", KERNEL_DEFINES[k]);
			return false;
		}
	}

	_disp_texture->set_texture_rd_rid(_disp_tex);
	_slope_texture->set_texture_rd_rid(_slope_tex);
	_free_retired();
	_built_resolution = n;
	_texture_generation.fetch_add(1);
	return true;
}

void Pasture3DWaterFFT::_free_retired() {
	for (const RID &t : _retired_textures) {
		if (_rd && t.is_valid() && _rd->texture_is_valid(t)) {
			_rd->free_rid(t);
		}
	}
	_retired_textures.clear();
}

void Pasture3DWaterFFT::_free_resources(const bool p_keep_outputs) {
	if (!_rd) {
		return;
	}
	if (p_keep_outputs) {
		// A RESOLUTION CHANGE, with materials still holding the wrappers. Detaching would free the RS
		// texture whose RID those materials stored when the profile was uploaded, and every one of them
		// would then draw a dead RID until something re-uploaded. So the output textures outlive this
		// free: _build_resources() points the wrappers at the new ones (set_texture_rd_rid replaces in
		// place and keeps the RS RID), and only then are these released.
		_retired_textures.push_back(_disp_tex);
		_retired_textures.push_back(_slope_tex);
		_disp_tex = RID();
		_slope_tex = RID();
	} else {
		// Detach the wrappers first: a material may still hold them, and an RS texture over a freed RD
		// texture is an error on every draw rather than an empty sample.
		if (_disp_texture.is_valid()) {
			_disp_texture->set_texture_rd_rid(RID());
		}
		if (_slope_texture.is_valid()) {
			_slope_texture->set_texture_rd_rid(RID());
		}
		_free_retired();
	}
	// Sets before views before textures. Freeing a texture also frees whatever depends on it, so each
	// free is guarded by a validity check rather than relying on the order alone.
	for (const RID &set : _downsample_sets) {
		if (_rd->uniform_set_is_valid(set)) {
			_rd->free_rid(set);
		}
	}
	_downsample_sets.clear();
	for (int k = 0; k < K_DOWNSAMPLE; k++) {
		if (_sets[k].is_valid() && _rd->uniform_set_is_valid(_sets[k])) {
			_rd->free_rid(_sets[k]);
		}
		_sets[k] = RID();
	}
	for (const RID &v : _disp_views) {
		if (_rd->texture_is_valid(v)) {
			_rd->free_rid(v);
		}
	}
	for (const RID &v : _slope_views) {
		if (_rd->texture_is_valid(v)) {
			_rd->free_rid(v);
		}
	}
	_disp_views.clear();
	_slope_views.clear();
	RID *textures[] = { &_initial_tex, &_spectrum_tex, &_disp_tex, &_slope_tex };
	for (RID *t : textures) {
		if (t->is_valid() && _rd->texture_is_valid(*t)) {
			_rd->free_rid(*t);
		}
		*t = RID();
	}
	if (_params_buffer.is_valid()) {
		_rd->free_rid(_params_buffer);
		_params_buffer = RID();
	}
	_built_resolution = 0;
}

void Pasture3DWaterFFT::_free_kernels() {
	if (!_rd) {
		return;
	}
	for (int k = 0; k < K_COUNT; k++) {
		if (_pipelines[k].is_valid() && _rd->compute_pipeline_is_valid(_pipelines[k])) {
			_rd->free_rid(_pipelines[k]);
		}
		_pipelines[k] = RID();
		if (_shaders[k].is_valid()) {
			_rd->free_rid(_shaders[k]);
		}
		_shaders[k] = RID();
	}
}

void Pasture3DWaterFFT::_write_params() {
	float f[PARAM_FLOATS] = {};
	for (int s = 0; s < 2; s++) {
		PackedFloat32Array sp = get_spectrum_params(s);
		for (int i = 0; i < 8; i++) {
			f[s * 8 + i] = sp[i];
		}
	}
	Vector4 lo = get_band_low();
	Vector4 hi = get_band_high();
	for (int i = 0; i < CASCADES; i++) {
		f[16 + i] = _cascade_lengths[i];
		f[20 + i] = lo[i];
		f[24 + i] = hi[i];
	}
	f[28] = _choppiness;
	f[29] = _choppiness;
	f[30] = GRAVITY;
	f[31] = _depth;
	f[32] = _loop_period;
	f[33] = _foam_bias;
	f[34] = _foam_threshold;
	f[35] = _foam_add;
	f[36] = _foam_decay;
	uint32_t seed = (uint32_t)_seed;
	memcpy(&f[37], &seed, sizeof(seed));
	PackedByteArray bytes;
	bytes.resize(PARAM_FLOATS * 4);
	memcpy(bytes.ptrw(), f, PARAM_FLOATS * 4);
	_rd->buffer_update(_params_buffer, 0, PARAM_FLOATS * 4, bytes);
}

static PackedByteArray push_bytes(const float p_a, const float p_b) {
	float f[4] = { p_a, p_b, 0.f, 0.f };
	PackedByteArray bytes;
	bytes.resize(16);
	memcpy(bytes.ptrw(), f, 16);
	return bytes;
}

void Pasture3DWaterFFT::_render_update(const float p_time, const float p_dt) {
	if (!_ensure_device()) {
		return;
	}
	if (_built_resolution != _resolution) {
		// Kernels are compiled per N (it is a #define), so they go too.
		_free_resources(_built_resolution != 0);
		_free_kernels();
		if (!_compile_kernels() || !_build_resources()) {
			_free_resources();
			_free_kernels();
			_init_failed = true;
			_rd = nullptr;
			return;
		}
		_spectrum_dirty = true;
		_params_dirty = true;
	}
	if (_params_dirty) {
		_write_params();
		_params_dirty = false;
	}

	const int n = _resolution;
	const int groups = (n + 7) / 8;
	// One compute list per kernel. Each list declares its uniform sets, so the render graph orders the
	// dispatches by their resource usage; a single list would need hand-placed barriers between them.
	auto dispatch = [&](const Kernel p_kernel, const RID &p_set, const PackedByteArray &p_push, const int p_x,
							const int p_y) {
		int64_t list = _rd->compute_list_begin();
		_rd->compute_list_bind_compute_pipeline(list, _pipelines[p_kernel]);
		_rd->compute_list_bind_uniform_set(list, p_set, 0);
		if (!p_push.is_empty()) {
			_rd->compute_list_set_push_constant(list, p_push, p_push.size());
		}
		_rd->compute_list_dispatch(list, p_x, p_y, 1);
		_rd->compute_list_end();
	};
	const PackedByteArray none;
	if (_spectrum_dirty) {
		dispatch(K_INIT, _sets[K_INIT], none, groups, groups);
		dispatch(K_PACK, _sets[K_PACK], none, groups, groups);
		_spectrum_dirty = false;
	}
	dispatch(K_UPDATE, _sets[K_UPDATE], push_bytes(p_time, p_dt), groups, groups);
	dispatch(K_FFT_H, _sets[K_FFT_H], none, 1, n);
	dispatch(K_FFT_V, _sets[K_FFT_V], none, 1, n);
	dispatch(K_ASSEMBLE, _sets[K_ASSEMBLE], push_bytes(p_time, p_dt), groups, groups);
	for (int m = 1; m < _mip_count; m++) {
		int size = n >> m;
		uint32_t pc[4] = { (uint32_t)size, 0u, 0u, 0u };
		PackedByteArray bytes;
		bytes.resize(16);
		memcpy(bytes.ptrw(), pc, 16);
		dispatch(K_DOWNSAMPLE, _downsample_sets[m - 1], bytes, (size + 7) / 8, (size + 7) / 8);
	}
	_update_count++;
}

PackedByteArray Pasture3DWaterFFT::_render_read(const int p_output, const int p_layer, const int p_mip) {
	PackedByteArray out;
	if (!_rd || _built_resolution == 0) {
		return out;
	}
	RID tex;
	int bytes_per_texel = 8;
	switch (p_output) {
		case OUTPUT_INITIAL_SPECTRUM:
			tex = _initial_tex;
			bytes_per_texel = 16;
			break;
		case OUTPUT_SPECTRUM:
			tex = _spectrum_tex;
			bytes_per_texel = 16;
			break;
		case OUTPUT_DISPLACEMENT:
			tex = _disp_tex;
			break;
		case OUTPUT_SLOPE:
			tex = _slope_tex;
			break;
		default:
			return out;
	}
	PackedByteArray all = _rd->texture_get_data(tex, p_layer);
	// The whole mip chain of the layer comes back, largest first.
	int64_t offset = 0;
	int size = _built_resolution;
	for (int m = 0; m < p_mip && size > 1; m++) {
		offset += (int64_t)size * size * bytes_per_texel;
		size >>= 1;
	}
	int64_t len = (int64_t)size * size * bytes_per_texel;
	if (offset + len > all.size()) {
		return out;
	}
	return all.slice(offset, offset + len);
}

void Pasture3DWaterFFT::_knob_changed(const bool p_respectrum, const bool p_emit) {
	_params_dirty = true;
	if (p_respectrum) {
		_spectrum_dirty = true;
		_sigma_dirty = true;
	}
	// A profile listens for this and re-uploads, which is how an inspector drag reaches the materials.
	// The manager-driven knobs (resolution, loop period) do not emit: neither changes what a material
	// holds -- a rebuild keeps the texture RIDs -- and a profile reads `changed` as "an artist edited the
	// sea", which a manager push is not.
	if (p_emit) {
		emit_changed();
	}
}

///////////////////////////
// Public Functions
///////////////////////////

Pasture3DWaterFFT::Pasture3DWaterFFT() {
	_disp_texture.instantiate();
	_slope_texture.instantiate();
	// The swell defaults: longer, older, more directional than the wind sea. U=12 m/s over 300 km peaks
	// near 133 m, a quarter of the longest tile; the wind sea (10 m/s, 100 km) peaks near 57 m.
	_spectra[1].scale = 0.5f;
	_spectra[1].wind_speed = 12.f;
	_spectra[1].direction_deg = 30.f;
	_spectra[1].fetch = 300000.f;
	_spectra[1].swell = 1.f;
}

Pasture3DWaterFFT::~Pasture3DWaterFFT() {
	_free_resources();
	_free_kernels();
}

bool Pasture3DWaterFFT::is_supported() {
	return RS && RS->get_rendering_device() != nullptr;
}

bool Pasture3DWaterFFT::is_available() {
	return !_init_failed && is_supported();
}

void Pasture3DWaterFFT::update(const float p_time, const float p_dt) {
	if (!is_available()) {
		return;
	}
	RS->call_on_render_thread(callable_mp(this, &Pasture3DWaterFFT::_render_update).bind(p_time, p_dt));
}

PackedByteArray Pasture3DWaterFFT::read_layer(const int p_output, const int p_layer, const int p_mip) {
	// texture_get_data on the main device flushes and stalls. Called directly rather than through
	// call_on_render_thread, which cannot return a value: this needs the single-threaded renderer, which
	// is the project default and what every gate runs under.
	return _render_read(p_output, p_layer, p_mip);
}

Vector4 Pasture3DWaterFFT::get_band_low() const {
	Vector4 hi = get_band_high();
	Vector4 lo;
	lo[0] = 1e-4f;
	for (int i = 1; i < CASCADES; i++) {
		lo[i] = _band_limited ? hi[i - 1] : 1e-4f;
	}
	return lo;
}

Vector4 Pasture3DWaterFFT::get_band_high() const {
	Vector4 hi;
	for (int i = 0; i < CASCADES; i++) {
		if (!_band_limited || i == CASCADES - 1) {
			// The reference's _HighCutoff. Past the grid's corner there are no samples anyway.
			hi[i] = 9000.f;
			continue;
		}
		// gasgiant's split: hand over to the next cascade six of its fundamentals in, so each cascade's
		// lowest modes -- the ones a tile repeat makes most visible -- come from the cascade above. Capped
		// at this cascade's Nyquist so nothing it cannot represent is assigned to it.
		float handover = 6.f * (float)Math_TAU / _cascade_lengths[i + 1];
		float nyquist = (float)Math_PI * (float)_resolution / _cascade_lengths[i];
		hi[i] = MIN(handover, nyquist);
	}
	return hi;
}

PackedFloat32Array Pasture3DWaterFFT::get_spectrum_params(const int p_spectrum) const {
	PackedFloat32Array out;
	out.resize(8);
	if (p_spectrum < 0 || p_spectrum > 1) {
		return out;
	}
	const SpectrumKnobs &k = _spectra[p_spectrum];
	float wind = MAX(k.wind_speed, 0.01f);
	float fetch = MAX(k.fetch, 1.f);
	out[0] = k.scale;
	out[1] = k.direction_deg / 180.f * (float)Math_PI;
	out[2] = k.spread_blend;
	out[3] = CLAMP(k.swell, 0.01f, 1.f);
	// JONSWAP fetch-limited alpha and peak frequency, as the reference's FillSpectrumStruct.
	out[4] = 0.076f * std::pow(GRAVITY * fetch / wind / wind, -0.22f);
	out[5] = 22.f * std::pow(wind * fetch / GRAVITY / GRAVITY, -0.33f);
	out[6] = k.peak_enhancement;
	out[7] = k.short_waves_fade;
	return out;
}

void Pasture3DWaterFFT::set_resolution(const int p_resolution) {
	// Powers of two only, and no 1024: the FFT's shared memory is 2 * N * 16 bytes, and 32 KB is past
	// Vulkan's guaranteed 16 KB.
	int r = p_resolution <= 128 ? 128 : (p_resolution <= 256 ? 256 : 512);
	if (r == _resolution) {
		return;
	}
	_resolution = r;
	_knob_changed(true, false);
}

void Pasture3DWaterFFT::set_seed(const int p_seed) {
	if (p_seed == _seed) {
		return;
	}
	_seed = p_seed;
	_knob_changed(true);
}

void Pasture3DWaterFFT::set_depth(const float p_depth) {
	float d = MAX(p_depth, 0.1f);
	if (d == _depth) {
		return;
	}
	_depth = d;
	_knob_changed(true);
}

void Pasture3DWaterFFT::set_choppiness(const float p_choppiness) {
	if (p_choppiness == _choppiness) {
		return;
	}
	_choppiness = p_choppiness;
	_knob_changed(false);
}

void Pasture3DWaterFFT::set_loop_period(const float p_seconds) {
	float s = MAX(p_seconds, 1.f);
	if (s == _loop_period) {
		return;
	}
	_loop_period = s;
	_knob_changed(false, false);
}

void Pasture3DWaterFFT::set_cascade_lengths(const Vector4 &p_lengths) {
	// Descending, and positive: the band split assumes cascade 0 is the longest.
	float l[CASCADES] = { p_lengths.x, p_lengths.y, p_lengths.z, p_lengths.w };
	for (int i = 0; i < CASCADES; i++) {
		l[i] = MAX(l[i], 0.25f);
	}
	for (int i = 0; i < CASCADES; i++) {
		for (int j = i + 1; j < CASCADES; j++) {
			if (l[j] > l[i]) {
				SWAP(l[i], l[j]);
			}
		}
	}
	Vector4 v(l[0], l[1], l[2], l[3]);
	if (v == _cascade_lengths) {
		return;
	}
	_cascade_lengths = v;
	_knob_changed(true);
}

void Pasture3DWaterFFT::set_band_limited(const bool p_enabled) {
	if (p_enabled == _band_limited) {
		return;
	}
	_band_limited = p_enabled;
	_knob_changed(true);
}

static float *knob_ptr(Pasture3DWaterFFT::SpectrumKnobs &p_k, const StringName &p_knob) {
	if (p_knob == StringName("scale")) {
		return &p_k.scale;
	} else if (p_knob == StringName("wind_speed")) {
		return &p_k.wind_speed;
	} else if (p_knob == StringName("direction_deg")) {
		return &p_k.direction_deg;
	} else if (p_knob == StringName("fetch")) {
		return &p_k.fetch;
	} else if (p_knob == StringName("spread_blend")) {
		return &p_k.spread_blend;
	} else if (p_knob == StringName("swell")) {
		return &p_k.swell;
	} else if (p_knob == StringName("peak_enhancement")) {
		return &p_k.peak_enhancement;
	} else if (p_knob == StringName("short_waves_fade")) {
		return &p_k.short_waves_fade;
	}
	return nullptr;
}

/**
 * The spectrum's variance, integrated in 1D on the CPU.
 *
 * The same terms the INIT kernel multiplies -- JONSWAP, TMA, short-wave fade, dw/dk -- with the directional
 * spread integrated out analytically: cosine-2s integrates to 1 over the circle, and the reference's cos^2
 * half to 2, so a spectrum at spread_blend b carries (2 - b) of its energy. Integrated from half the longest
 * tile's fundamental to the shortest tile's Nyquist, which is the range the cascades hold. The Nyquist row
 * the kernel leaves empty is a sliver of the shortest cascade and is ignored.
 */
float Pasture3DWaterFFT::get_height_sigma() const {
	if (!_sigma_dirty) {
		return _sigma;
	}
	const double g = GRAVITY;
	const double depth = MAX(_depth, 0.01f);
	const double k0 = 0.5 * Math_TAU / MAX(_cascade_lengths[0], 0.01f);
	const double k1 = Math_PI * (double)_resolution / MAX(_cascade_lengths[CASCADES - 1], 0.01f);
	PackedFloat32Array sp[2] = { get_spectrum_params(0), get_spectrum_params(1) };
	const int steps = 4000;
	double total = 0.0;
	double prev_k = k0;
	double prev_f = 0.0;
	for (int i = 0; i <= steps; i++) {
		double k = k0 * std::pow(k1 / k0, (double)i / steps);
		double kd = MIN(k * depth, 20.0);
		double th = std::tanh(kd);
		double omega = std::sqrt(g * k * th);
		double ch = std::cosh(kd);
		double domega = g * (depth * k / ch / ch + th) / omega / 2.0;
		double oh = omega * std::sqrt(depth / g);
		double tma = oh <= 1.0 ? 0.5 * oh * oh : (oh < 2.0 ? 1.0 - 0.5 * (2.0 - oh) * (2.0 - oh) : 1.0);
		double f = 0.0;
		for (int si = 0; si < 2; si++) {
			const float *p = sp[si].ptr();
			if (si == 1 && p[0] <= 0.f) {
				continue;
			}
			double peak = p[5];
			double sigma = omega <= peak ? 0.07 : 0.09;
			double r = std::exp(-(omega - peak) * (omega - peak) / 2.0 / sigma / sigma / peak / peak);
			double s = p[0] * tma * p[4] * g * g / std::pow(omega, 5.0) * std::exp(-1.25 * std::pow(peak / omega, 4.0)) *
					std::pow(std::abs((double)p[6]), r);
			double spread = 2.0 - CLAMP((double)p[2], 0.0, 1.0);
			f += s * spread * std::exp(-(double)p[7] * p[7] * k * k) * domega;
		}
		if (i > 0) {
			total += 0.5 * (f + prev_f) * (k - prev_k);
		}
		prev_k = k;
		prev_f = f;
	}
	_sigma = (float)std::sqrt(MAX(total, 0.0));
	_sigma_dirty = false;
	return _sigma;
}

void Pasture3DWaterFFT::set_spectrum_knob(const int p_spectrum, const StringName &p_knob, const float p_value) {
	ERR_FAIL_INDEX(p_spectrum, 2);
	float *v = knob_ptr(_spectra[p_spectrum], p_knob);
	ERR_FAIL_NULL_MSG(v, vformat("Unknown spectrum knob '%s'", String(p_knob)));
	if (*v == p_value) {
		return;
	}
	*v = p_value;
	_knob_changed(true);
}

float Pasture3DWaterFFT::get_spectrum_knob(const int p_spectrum, const StringName &p_knob) const {
	ERR_FAIL_INDEX_V(p_spectrum, 2, 0.f);
	float *v = knob_ptr(const_cast<SpectrumKnobs &>(_spectra[p_spectrum]), p_knob);
	ERR_FAIL_NULL_V_MSG(v, 0.f, vformat("Unknown spectrum knob '%s'", String(p_knob)));
	return *v;
}

void Pasture3DWaterFFT::set_foam_bias(const float p_value) {
	if (p_value != _foam_bias) {
		_foam_bias = p_value;
		_knob_changed(false);
	}
}

void Pasture3DWaterFFT::set_foam_threshold(const float p_value) {
	if (p_value != _foam_threshold) {
		_foam_threshold = p_value;
		_knob_changed(false);
	}
}

void Pasture3DWaterFFT::set_foam_add(const float p_value) {
	if (p_value != _foam_add) {
		_foam_add = p_value;
		_knob_changed(false);
	}
}

void Pasture3DWaterFFT::set_foam_decay(const float p_value) {
	if (p_value != _foam_decay) {
		_foam_decay = p_value;
		_knob_changed(false);
	}
}

///////////////////////////
// Protected Functions
///////////////////////////

// The two spectra's knobs as "wind/<knob>" and "swell/<knob>". Dynamic rather than sixteen bound
// setters, because they are one struct twice and the knob names are already the API (set_spectrum_knob).
static const char *SPECTRUM_PREFIX[2] = { "wind/", "swell/" };
static const char *SPECTRUM_KNOBS[] = { "scale", "wind_speed", "direction_deg", "fetch", "spread_blend", "swell",
	"peak_enhancement", "short_waves_fade" };
static const char *SPECTRUM_HINTS[] = { "0,4,0.01,or_greater", "0.1,40,0.1,suffix:m/s", "-180,180,0.5,degrees",
	"10,1000000,10,exp,suffix:m", "0,1,0.01", "0.01,1,0.01", "1,10,0.01", "0,1,0.001,suffix:m" };

static bool split_spectrum_name(const StringName &p_name, int &r_spectrum, StringName &r_knob) {
	String n = p_name;
	for (int i = 0; i < 2; i++) {
		if (n.begins_with(SPECTRUM_PREFIX[i])) {
			r_spectrum = i;
			r_knob = n.substr(String(SPECTRUM_PREFIX[i]).length());
			return true;
		}
	}
	return false;
}

bool Pasture3DWaterFFT::_set(const StringName &p_name, const Variant &p_value) {
	int spectrum;
	StringName knob;
	if (!split_spectrum_name(p_name, spectrum, knob) || !knob_ptr(_spectra[spectrum], knob)) {
		return false;
	}
	set_spectrum_knob(spectrum, knob, (float)p_value);
	return true;
}

bool Pasture3DWaterFFT::_get(const StringName &p_name, Variant &r_ret) const {
	int spectrum;
	StringName knob;
	if (!split_spectrum_name(p_name, spectrum, knob) ||
			!knob_ptr(const_cast<SpectrumKnobs &>(_spectra[spectrum]), knob)) {
		return false;
	}
	r_ret = get_spectrum_knob(spectrum, knob);
	return true;
}

void Pasture3DWaterFFT::_get_property_list(List<PropertyInfo> *p_list) const {
	for (int i = 0; i < 2; i++) {
		for (int k = 0; k < 8; k++) {
			p_list->push_back(PropertyInfo(Variant::FLOAT, String(SPECTRUM_PREFIX[i]) + SPECTRUM_KNOBS[k],
					PROPERTY_HINT_RANGE, SPECTRUM_HINTS[k]));
		}
	}
}

void Pasture3DWaterFFT::_bind_methods() {
	BIND_ENUM_CONSTANT(OUTPUT_INITIAL_SPECTRUM);
	BIND_ENUM_CONSTANT(OUTPUT_SPECTRUM);
	BIND_ENUM_CONSTANT(OUTPUT_DISPLACEMENT);
	BIND_ENUM_CONSTANT(OUTPUT_SLOPE);

	ClassDB::bind_static_method("Pasture3DWaterFFT", D_METHOD("is_supported"), &Pasture3DWaterFFT::is_supported);
	ClassDB::bind_method(D_METHOD("is_available"), &Pasture3DWaterFFT::is_available);
	ClassDB::bind_method(D_METHOD("update", "time", "delta"), &Pasture3DWaterFFT::update);
	ClassDB::bind_method(D_METHOD("get_update_count"), &Pasture3DWaterFFT::get_update_count);
	ClassDB::bind_method(D_METHOD("get_texture_generation"), &Pasture3DWaterFFT::get_texture_generation);
	ClassDB::bind_method(D_METHOD("get_displacement_texture"), &Pasture3DWaterFFT::get_displacement_texture);
	ClassDB::bind_method(D_METHOD("get_slope_texture"), &Pasture3DWaterFFT::get_slope_texture);
	ClassDB::bind_method(D_METHOD("get_band_low"), &Pasture3DWaterFFT::get_band_low);
	ClassDB::bind_method(D_METHOD("get_band_high"), &Pasture3DWaterFFT::get_band_high);
	ClassDB::bind_method(D_METHOD("read_layer", "output", "layer", "mip"), &Pasture3DWaterFFT::read_layer, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_spectrum_params", "spectrum"), &Pasture3DWaterFFT::get_spectrum_params);
	ClassDB::bind_method(D_METHOD("set_spectrum_knob", "spectrum", "knob", "value"), &Pasture3DWaterFFT::set_spectrum_knob);
	ClassDB::bind_method(D_METHOD("get_spectrum_knob", "spectrum", "knob"), &Pasture3DWaterFFT::get_spectrum_knob);

	ClassDB::bind_method(D_METHOD("set_resolution", "resolution"), &Pasture3DWaterFFT::set_resolution);
	ClassDB::bind_method(D_METHOD("get_resolution"), &Pasture3DWaterFFT::get_resolution);
	ClassDB::bind_method(D_METHOD("set_seed", "seed"), &Pasture3DWaterFFT::set_seed);
	ClassDB::bind_method(D_METHOD("get_seed"), &Pasture3DWaterFFT::get_seed);
	ClassDB::bind_method(D_METHOD("set_depth", "metres"), &Pasture3DWaterFFT::set_depth);
	ClassDB::bind_method(D_METHOD("get_depth"), &Pasture3DWaterFFT::get_depth);
	ClassDB::bind_method(D_METHOD("set_choppiness", "choppiness"), &Pasture3DWaterFFT::set_choppiness);
	ClassDB::bind_method(D_METHOD("get_choppiness"), &Pasture3DWaterFFT::get_choppiness);
	ClassDB::bind_method(D_METHOD("set_loop_period", "seconds"), &Pasture3DWaterFFT::set_loop_period);
	ClassDB::bind_method(D_METHOD("get_loop_period"), &Pasture3DWaterFFT::get_loop_period);
	ClassDB::bind_method(D_METHOD("set_cascade_lengths", "lengths"), &Pasture3DWaterFFT::set_cascade_lengths);
	ClassDB::bind_method(D_METHOD("get_cascade_lengths"), &Pasture3DWaterFFT::get_cascade_lengths);
	ClassDB::bind_method(D_METHOD("set_band_limited", "enabled"), &Pasture3DWaterFFT::set_band_limited);
	ClassDB::bind_method(D_METHOD("get_band_limited"), &Pasture3DWaterFFT::get_band_limited);
	ClassDB::bind_method(D_METHOD("set_foam_bias", "value"), &Pasture3DWaterFFT::set_foam_bias);
	ClassDB::bind_method(D_METHOD("get_foam_bias"), &Pasture3DWaterFFT::get_foam_bias);
	ClassDB::bind_method(D_METHOD("set_foam_threshold", "value"), &Pasture3DWaterFFT::set_foam_threshold);
	ClassDB::bind_method(D_METHOD("get_foam_threshold"), &Pasture3DWaterFFT::get_foam_threshold);
	ClassDB::bind_method(D_METHOD("set_foam_add", "per_second"), &Pasture3DWaterFFT::set_foam_add);
	ClassDB::bind_method(D_METHOD("get_foam_add"), &Pasture3DWaterFFT::get_foam_add);
	ClassDB::bind_method(D_METHOD("set_foam_decay", "per_second"), &Pasture3DWaterFFT::set_foam_decay);
	ClassDB::bind_method(D_METHOD("get_foam_decay"), &Pasture3DWaterFFT::get_foam_decay);

	ClassDB::bind_method(D_METHOD("get_height_sigma"), &Pasture3DWaterFFT::get_height_sigma);
	ClassDB::bind_method(D_METHOD("get_displacement_bound"), &Pasture3DWaterFFT::get_displacement_bound);

	// Manager-driven: bound so a gate can drive a standalone simulation, never stored.
	ADD_PROPERTY(PropertyInfo(Variant::INT, "resolution", PROPERTY_HINT_ENUM, "128:128,256:256,512:512", PROPERTY_USAGE_NONE), "set_resolution", "get_resolution");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "seed"), "set_seed", "get_seed");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "depth", PROPERTY_HINT_RANGE, "0.1,500.0,0.1,or_greater,suffix:m"), "set_depth", "get_depth");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "choppiness", PROPERTY_HINT_RANGE, "0.0,3.0,0.01"), "set_choppiness", "get_choppiness");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "loop_period", PROPERTY_HINT_RANGE, "1.0,600.0,0.1,suffix:s", PROPERTY_USAGE_NONE), "set_loop_period", "get_loop_period");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR4, "cascade_lengths", PROPERTY_HINT_NONE, "suffix:m"), "set_cascade_lengths", "get_cascade_lengths");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "band_limited"), "set_band_limited", "get_band_limited");
	ADD_GROUP("Foam", "foam_");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "foam_bias", PROPERTY_HINT_RANGE, "-2.0,2.0,0.01"), "set_foam_bias", "get_foam_bias");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "foam_threshold", PROPERTY_HINT_RANGE, "-10.0,10.0,0.01"), "set_foam_threshold", "get_foam_threshold");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "foam_add", PROPERTY_HINT_RANGE, "0.0,60.0,0.01,suffix:/s"), "set_foam_add", "get_foam_add");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "foam_decay", PROPERTY_HINT_RANGE, "0.0,60.0,0.01,suffix:/s"), "set_foam_decay", "get_foam_decay");
}
