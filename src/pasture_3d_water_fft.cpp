// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/rd_shader_source.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <cmath>
#include <cstring>
#include <vector>

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

// Floats in the kernel's Params block (std430): 8 spectra x 8, three vec4s, then 12 scalars.
static constexpr int PARAM_FLOATS = 88;
static constexpr int PARAM_SPECTRA_FLOATS = Pasture3DWaterFFT::SPECTRA * 8;

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
	for (int s = 0; s < SPECTRA; s++) {
		PackedFloat32Array sp = get_spectrum_params(s);
		for (int i = 0; i < 8; i++) {
			f[s * 8 + i] = sp[i];
		}
	}
	const int b = PARAM_SPECTRA_FLOATS;
	Vector4 lo = get_band_low();
	Vector4 hi = get_band_high();
	for (int i = 0; i < CASCADES; i++) {
		f[b + i] = _cascade_lengths[i];
		f[b + 4 + i] = lo[i];
		f[b + 8 + i] = hi[i];
	}
	f[b + 12] = _choppiness;
	f[b + 13] = _choppiness;
	f[b + 14] = GRAVITY;
	f[b + 15] = _depth;
	f[b + 16] = _loop_period;
	f[b + 17] = _foam_bias;
	f[b + 18] = _foam_threshold;
	f[b + 19] = _foam_add;
	f[b + 20] = _foam_decay;
	uint32_t seed = (uint32_t)_seed;
	memcpy(&f[b + 21], &seed, sizeof(seed));
	PackedByteArray bytes;
	bytes.resize(PARAM_FLOATS * 4);
	memcpy(bytes.ptrw(), f, PARAM_FLOATS * 4);
	_rd->buffer_update(_params_buffer, 0, PARAM_FLOATS * 4, bytes);
}

// Every kernel's push constant is 16 bytes: two floats (UPDATE, ASSEMBLE: time and dt; DOWNSAMPLE: the
// destination size as uint bits), then the cascade mask the kernel skips the rest of.
static PackedByteArray push_bytes(const float p_a, const float p_b, const uint32_t p_mask) {
	float f[4] = { p_a, p_b, 0.f, 0.f };
	memcpy(&f[2], &p_mask, 4);
	PackedByteArray bytes;
	bytes.resize(16);
	memcpy(bytes.ptrw(), f, 16);
	return bytes;
}

void Pasture3DWaterFFT::_render_update(const float p_time, const float p_dt, const bool p_readback) {
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
		// Every cascade, drawn or not, so that drawing one later needs no re-initialisation.
		dispatch(K_INIT, _sets[K_INIT], none, groups, groups);
		dispatch(K_PACK, _sets[K_PACK], none, groups, groups);
		_spectrum_dirty = false;
	}
	// The per-frame kernels run only the drawn cascades (spec G2): a hidden one keeps its last frame.
	const uint32_t drawn = (uint32_t)(_cascade_drawn & 0xf);
	dispatch(K_UPDATE, _sets[K_UPDATE], push_bytes(p_time, p_dt, drawn), groups, groups);
	dispatch(K_FFT_H, _sets[K_FFT_H], push_bytes(0.f, 0.f, drawn), 1, n);
	dispatch(K_FFT_V, _sets[K_FFT_V], push_bytes(0.f, 0.f, drawn), 1, n);
	dispatch(K_ASSEMBLE, _sets[K_ASSEMBLE], push_bytes(p_time, p_dt, drawn), groups, groups);
	for (int m = 1; m < _mip_count; m++) {
		const uint32_t size = (uint32_t)(n >> m);
		float size_bits;
		memcpy(&size_bits, &size, 4);
		dispatch(K_DOWNSAMPLE, _downsample_sets[m - 1], push_bytes(size_bits, 0.f, drawn), (size + 7) / 8,
				(size + 7) / 8);
	}
	_update_count++;

	const int displacing = get_displacing_mask();
	if (p_readback && displacing != 0) {
		// Queued after AssembleMaps (and the mips, which the copy does not need but cannot skip: a layer's
		// download carries its whole chain). The device delivers each layer when the frame completes. Only
		// the displacing cascades: the others move nothing a buoy could ride.
		PendingReadback pending;
		pending.surface.resolution = n;
		pending.surface.repeats = get_cascade_repeats();
		pending.surface.displaces = displacing;
		pending.surface.time = p_time;
		pending.surface.update = _update_count;
		{
			std::lock_guard<std::mutex> lock(_readback_mutex);
			if (_pending.size() >= READBACK_MAX_PENDING) {
				_pending.remove_at(0);
			}
			_pending.push_back(pending);
		}
		for (int c = 0; c < CASCADES; c++) {
			if (displacing & (1 << c)) {
				_rd->texture_get_data_async(_disp_tex, c,
						callable_mp(this, &Pasture3DWaterFFT::_on_readback).bind(c, _update_count));
			}
		}
	}
}

void Pasture3DWaterFFT::_on_readback(const PackedByteArray &p_data, const int p_layer, const int p_update) {
	std::lock_guard<std::mutex> lock(_readback_mutex);
	int index = -1;
	for (int i = 0; i < _pending.size(); i++) {
		if (_pending[i].surface.update == p_update) {
			index = i;
			break;
		}
	}
	if (index < 0 || p_layer < 0 || p_layer >= CASCADES) {
		return; // abandoned, or superseded by a newer complete frame
	}
	PendingReadback &pending = _pending.write[index];
	const int64_t bytes = (int64_t)pending.surface.resolution * pending.surface.resolution * 8;
	if (p_data.size() < bytes) {
		_pending.remove_at(index);
		return;
	}
	// Mip 0 leads the layer's chain.
	pending.surface.layers[p_layer] = p_data.size() == bytes ? p_data : p_data.slice(0, bytes);
	pending.received |= 1 << p_layer;
	if (pending.received != pending.surface.displaces) {
		return;
	}
	if (pending.surface.update > _cpu_surface.update) {
		_cpu_surface = pending.surface;
		_readback_count++;
	}
	// This frame and everything older is done with: an older one still pending would only be discarded.
	_pending = _pending.slice(index + 1);
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
	// The reference's SampleScene spectrum1..spectrum8: scale, wind, direction, fetch, spread blend, swell,
	// peak enhancement, short-waves fade. PASTURE3D_WATER_REFERENCE_SPEC.md §2.
	static const float scene[SPECTRA][8] = {
		{ 0.1f, 2.f, 22.f, 100000.f, 0.642f, 1.f, 1.f, 0.025f },
		{ 0.07f, 2.f, 59.f, 1000.f, 0.f, 1.f, 1.f, 0.01f },
		{ 0.25f, 20.f, 97.f, 100000000.f, 0.14f, 1.f, 1.f, 0.5f },
		{ 0.25f, 20.f, 67.f, 1000000.f, 0.47f, 1.f, 1.f, 0.5f },
		{ 0.15f, 5.f, 105.f, 1000000.f, 0.2f, 1.f, 1.f, 0.5f },
		{ 0.1f, 1.f, 19.f, 10000.f, 0.298f, 0.695f, 1.f, 0.5f },
		{ 1.f, 1.f, 209.f, 200000.f, 0.56f, 1.f, 1.f, 0.0001f },
		{ 0.23f, 1.f, 0.f, 1000.f, 0.f, 0.f, 1.f, 0.0001f },
	};
	for (int i = 0; i < SPECTRA; i++) {
		SpectrumKnobs &k = _spectra[i];
		k.scale = scene[i][0];
		k.wind_speed = scene[i][1];
		k.direction_deg = scene[i][2];
		k.fetch = scene[i][3];
		k.spread_blend = scene[i][4];
		k.swell = scene[i][5];
		k.peak_enhancement = scene[i][6];
		k.short_waves_fade = scene[i][7];
	}
}

Pasture3DWaterFFT::~Pasture3DWaterFFT() {
	_free_resources();
	_free_kernels();
}

bool Pasture3DWaterFFT::is_supported() {
	return RS && RS->get_rendering_device() != nullptr;
}

int Pasture3DWaterFFT::snap_resolution(const int p_resolution) {
	int r = MIN_RESOLUTION;
	while (r < MAX_RESOLUTION && r < p_resolution) {
		r <<= 1;
	}
	return r;
}

int Pasture3DWaterFFT::resolution_for_limits(const int p_requested, const int64_t p_shared_bytes,
		const int64_t p_invocations, const int64_t p_size_x) {
	int r = snap_resolution(p_requested);
	while (r > MIN_RESOLUTION && (32 * (int64_t)r > p_shared_bytes || r > p_invocations || r > p_size_x)) {
		r >>= 1;
	}
	return r;
}

int Pasture3DWaterFFT::get_max_resolution() {
	RenderingDevice *rd = RS ? RS->get_rendering_device() : nullptr;
	if (!rd) {
		return MAX_RESOLUTION;
	}
	return resolution_for_limits(MAX_RESOLUTION, (int64_t)rd->limit_get(RenderingDevice::LIMIT_MAX_COMPUTE_SHARED_MEMORY_SIZE),
			(int64_t)rd->limit_get(RenderingDevice::LIMIT_MAX_COMPUTE_WORKGROUP_INVOCATIONS),
			(int64_t)rd->limit_get(RenderingDevice::LIMIT_MAX_COMPUTE_WORKGROUP_SIZE_X));
}

bool Pasture3DWaterFFT::is_available() {
	return !_init_failed && is_supported();
}

void Pasture3DWaterFFT::update(const float p_time, const float p_dt) {
	if (!is_available()) {
		return;
	}
	const bool readback = _main_updates - _cpu_demand_at <= READBACK_KEEPALIVE;
	_main_updates++;
	RS->call_on_render_thread(callable_mp(this, &Pasture3DWaterFFT::_render_update).bind(p_time, p_dt, readback));
}

Pasture3DWaterFFT::CpuSurface Pasture3DWaterFFT::get_cpu_surface() const {
	std::lock_guard<std::mutex> lock(_readback_mutex);
	return _cpu_surface;
}

int Pasture3DWaterFFT::get_readback_count() const {
	std::lock_guard<std::mutex> lock(_readback_mutex);
	return _readback_count;
}

int Pasture3DWaterFFT::get_readback_update() const {
	std::lock_guard<std::mutex> lock(_readback_mutex);
	return _cpu_surface.update;
}

float Pasture3DWaterFFT::get_readback_time() const {
	std::lock_guard<std::mutex> lock(_readback_mutex);
	return _cpu_surface.time;
}

// IEEE 754 binary16 to float, subnormals included. The output is rgba16f and godot-cpp has no decoder.
static inline float half_to_float(const uint16_t p_h) {
	const uint32_t sign = (uint32_t)(p_h & 0x8000u) << 16;
	uint32_t exponent = (p_h >> 10) & 0x1fu;
	uint32_t mantissa = p_h & 0x3ffu;
	uint32_t bits;
	if (exponent == 0) {
		if (mantissa == 0) {
			bits = sign;
		} else {
			// Subnormal: shift the mantissa up until its leading one is the implicit bit.
			exponent = 127 - 15 + 1;
			while (!(mantissa & 0x400u)) {
				mantissa <<= 1;
				exponent--;
			}
			bits = sign | (exponent << 23) | ((mantissa & 0x3ffu) << 13);
		}
	} else if (exponent == 0x1f) {
		bits = sign | 0x7f800000u | (mantissa << 13);
	} else {
		bits = sign | ((exponent + 127 - 15) << 23) | (mantissa << 13);
	}
	float f;
	memcpy(&f, &bits, 4);
	return f;
}

Vector3 Pasture3DWaterFFT::CpuSurface::sample(const Vector2 &p_domain_xz) const {
	Vector3 sum;
	if (!is_valid()) {
		return sum;
	}
	const int n = resolution;
	const int64_t bytes = (int64_t)n * n * 8;
	for (int c = 0; c < CASCADES; c++) {
		if (!(displaces & (1 << c)) || layers[c].size() < bytes || repeats[c] <= 0.f) {
			continue;
		}
		const uint16_t *texels = reinterpret_cast<const uint16_t *>(layers[c].ptr());
		// In double: a domain kilometres from the origin over a 4 m tile is a large texel coordinate.
		const double x = (double)p_domain_xz.x / repeats[c] * n - 0.5;
		const double z = (double)p_domain_xz.y / repeats[c] * n - 0.5;
		const double fx = std::floor(x);
		const double fz = std::floor(z);
		const float tx = (float)(x - fx);
		const float tz = (float)(z - fz);
		const int i0 = (int)(((int64_t)fx % n + n) % n);
		const int j0 = (int)(((int64_t)fz % n + n) % n);
		const int i1 = (i0 + 1) % n;
		const int j1 = (j0 + 1) % n;
		auto tap = [&](const int p_i, const int p_j) {
			const uint16_t *t = texels + ((int64_t)p_j * n + p_i) * 4;
			return Vector3(half_to_float(t[0]), half_to_float(t[1]), half_to_float(t[2]));
		};
		const Vector3 top = tap(i0, j0).lerp(tap(i1, j0), tx);
		const Vector3 bottom = tap(i0, j1).lerp(tap(i1, j1), tx);
		sum += top.lerp(bottom, tz);
	}
	return sum;
}

PackedByteArray Pasture3DWaterFFT::read_layer(const int p_output, const int p_layer, const int p_mip) {
	// texture_get_data on the main device flushes and stalls. Called directly rather than through
	// call_on_render_thread, which cannot return a value: this needs the single-threaded renderer, which
	// is the project default and what every gate runs under.
	return _render_read(p_output, p_layer, p_mip);
}

// The cascades from longest to shortest, ties in index order. The lengths are not sorted (the reference's
// scene runs 94, 128, 64, 32), so the band split walks this order instead.
static void cascades_by_length(const Vector4 &p_lengths, int r_order[Pasture3DWaterFFT::CASCADES]) {
	for (int i = 0; i < Pasture3DWaterFFT::CASCADES; i++) {
		r_order[i] = i;
	}
	for (int i = 1; i < Pasture3DWaterFFT::CASCADES; i++) {
		for (int j = i; j > 0 && p_lengths[r_order[j]] > p_lengths[r_order[j - 1]]; j--) {
			SWAP(r_order[j], r_order[j - 1]);
		}
	}
}

Vector4 Pasture3DWaterFFT::get_band_low() const {
	// The reference's _LowCutoff. It also keeps out k = 0, where dw/dk / k divides by zero.
	Vector4 lo(1e-4f, 1e-4f, 1e-4f, 1e-4f);
	if (!_band_limited) {
		return lo;
	}
	Vector4 hi = get_band_high();
	int order[CASCADES];
	cascades_by_length(_cascade_lengths, order);
	for (int n = 1; n < CASCADES; n++) {
		lo[order[n]] = hi[order[n - 1]];
	}
	return lo;
}

Vector4 Pasture3DWaterFFT::get_band_high() const {
	// The reference's _HighCutoff. Past the grid's corner there are no samples anyway.
	Vector4 hi(9000.f, 9000.f, 9000.f, 9000.f);
	if (!_band_limited) {
		return hi;
	}
	int order[CASCADES];
	cascades_by_length(_cascade_lengths, order);
	for (int n = 0; n < CASCADES - 1; n++) {
		const int i = order[n];
		// gasgiant's split: hand over to the next shorter cascade six of its fundamentals in, so each
		// cascade's lowest modes -- the ones a tile repeat makes most visible -- come from the cascade above.
		// Capped at this cascade's Nyquist so nothing it cannot represent is assigned to it.
		float handover = 6.f * (float)Math_TAU / _cascade_lengths[order[n + 1]];
		float nyquist = (float)Math_PI * (float)_resolution / _cascade_lengths[i];
		hi[i] = MIN(handover, nyquist);
	}
	return hi;
}

PackedFloat32Array Pasture3DWaterFFT::get_spectrum_params(const int p_spectrum) const {
	PackedFloat32Array out;
	out.resize(8);
	ERR_FAIL_INDEX_V(p_spectrum, SPECTRA, out);
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
	// Powers of two, and no more than the device runs (resolution_for_limits). 1024 needs 32 KB of shared
	// memory, which most desktop GPUs have and Vulkan does not promise.
	int r = snap_resolution(p_resolution);
	const int max_r = get_max_resolution();
	if (r > max_r) {
		LOG(WARN, "FFT resolution ", r, " needs more compute shared memory or workgroup size than this GPU has; running at ", max_r);
		r = max_r;
	}
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
	// In any order: cascade i is spectra 2i and 2i+1 whatever its length, and the band split sorts.
	Vector4 v(MAX(p_lengths.x, 0.25f), MAX(p_lengths.y, 0.25f), MAX(p_lengths.z, 0.25f), MAX(p_lengths.w, 0.25f));
	if (v == _cascade_lengths) {
		return;
	}
	_cascade_lengths = v;
	_knob_changed(true);
}

void Pasture3DWaterFFT::set_cascade_tiles(const Vector4 &p_tiles) {
	Vector4 v(MAX(p_tiles.x, 0.f), MAX(p_tiles.y, 0.f), MAX(p_tiles.z, 0.f), MAX(p_tiles.w, 0.f));
	if (v == _cascade_tiles) {
		return;
	}
	_cascade_tiles = v;
	_knob_changed(false);
}

void Pasture3DWaterFFT::set_cascade_drawn(const int p_mask) {
	const int m = p_mask & 0xf;
	if (m == _cascade_drawn) {
		return;
	}
	_cascade_drawn = m;
	_sigma_dirty = true; // the displacing set is drawn AND displaces
	_knob_changed(false);
}

void Pasture3DWaterFFT::set_cascade_displaces(const int p_mask) {
	const int m = p_mask & 0xf;
	if (m == _cascade_displaces) {
		return;
	}
	_cascade_displaces = m;
	_sigma_dirty = true;
	_knob_changed(false);
}

void Pasture3DWaterFFT::set_cascade_foam_offset(const Vector4 &p_offset) {
	if (p_offset == _cascade_foam_offset) {
		return;
	}
	_cascade_foam_offset = p_offset;
	_knob_changed(false);
}

Vector4 Pasture3DWaterFFT::get_cascade_repeats() const {
	Vector4 r;
	for (int i = 0; i < CASCADES; i++) {
		r[i] = _cascade_tiles[i] > 0.f ? _cascade_tiles[i] : _cascade_lengths[i];
	}
	return r;
}

float Pasture3DWaterFFT::get_foam_offset_sum() const {
	return _cascade_foam_offset.x + _cascade_foam_offset.y + _cascade_foam_offset.z + _cascade_foam_offset.w;
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

// The INIT kernel's spectrum terms in double, for get_height_sigma(). p is get_spectrum_params():
// [scale, angle_rad, spread_blend, swell, alpha, peak_omega, gamma, short_waves_fade].
namespace {
struct SeaTerms {
	double g = 0.0;
	double depth = 0.0;

	// w(k), dw/dk and the TMA correction at |k|.
	void dispersion(const double p_k, double &r_omega, double &r_domega, double &r_tma) const {
		const double kd = MIN(p_k * depth, 20.0);
		const double th = std::tanh(kd);
		const double ch = std::cosh(kd);
		r_omega = std::sqrt(g * p_k * th);
		r_domega = g * (depth * p_k / ch / ch + th) / r_omega / 2.0;
		const double oh = r_omega * std::sqrt(depth / g);
		r_tma = oh <= 1.0 ? 0.5 * oh * oh : (oh < 2.0 ? 1.0 - 0.5 * (2.0 - oh) * (2.0 - oh) : 1.0);
	}

	// JONSWAP x TMA x short-wave fade: everything but the directional spread.
	static double radial(const float *p, const double p_k, const double p_omega, const double p_tma, const double p_g) {
		const double peak = p[5];
		const double sigma = p_omega <= peak ? 0.07 : 0.09;
		const double r = std::exp(-(p_omega - peak) * (p_omega - peak) / 2.0 / sigma / sigma / peak / peak);
		return p[0] * p_tma * p[4] * p_g * p_g / std::pow(p_omega, 5.0) *
				std::exp(-1.25 * std::pow(peak / p_omega, 4.0)) * std::pow(std::abs((double)p[6]), r) *
				std::exp(-(double)p[7] * p[7] * p_k * p_k);
	}

	// The directional spread at angle theta, as the kernel's direction_spectrum(): cos^2 unrotated (S9).
	static double spread(const float *p, const double p_theta, const double p_omega) {
		const double ratio = p_omega / p[5];
		double s = ratio > 1.0 ? 9.77 * std::pow(ratio, -2.5) : 6.97 * std::pow(ratio, 5.0);
		s += 16.0 * std::tanh(MIN(ratio, 20.0)) * p[3] * p[3];
		const double s2 = s * s;
		const double s3 = s2 * s;
		const double s4 = s3 * s;
		const double norm = s < 5.0 ? -0.000564 * s4 + 0.00776 * s3 - 0.044 * s2 + 0.192 * s + 0.163
									: -4.80e-08 * s4 + 1.07e-05 * s3 - 9.53e-04 * s2 + 5.90e-02 * s + 3.93e-01;
		const double c2s = norm * std::pow(std::abs(std::cos(0.5 * (p_theta - p[1]))), 2.0 * s);
		const double c = std::cos(p_theta);
		return 2.0 / 3.1415 * c * c * (1.0 - p[2]) + c2s * p[2];
	}
};
} // namespace

/**
 * The sea's variance, on the CPU.
 *
 * Of the displacing cascades only (get_displacing_mask()): the others move nothing, and a sea whose bound
 * counted them would cull and fit to waves it does not draw.
 *
 * The expected spatial variance of a cascade's height is the sum, over the modes its grid holds, of
 * E|htilde(k)|^2 -- with the reference's h0, sqrt(2 Psi dk^2) per Gaussian pair, that is 8 Psi(k) dk^2 per
 * mode, Psi being the spectrum the INIT kernel builds: JONSWAP x TMA x fade x spread x dw/dk / k. The
 * cascades are independent draws, so their variances add -- and where they overlap (band_limited off, the
 * reference) the overlap counts in each, as the summed displacement carries it in each.
 *
 * Summed mode by mode out to LOW_RING fundamentals, then integrated in 1D with the spread integrated out
 * analytically (cosine-2s to 1 over the circle, the cos^2 half to 2, so a spectrum at spread_blend b
 * carries 2 - b). The sum is not optional: the reference's spectra peak far below its tiles' fundamentals,
 * so a cascade's energy sits in its first few rings of modes, where a continuum integral misjudges the
 * variance by up to 2x. The Nyquist row the kernel leaves empty is a sliver of each cascade and is ignored,
 * as are the grid's corners past the inscribed circle.
 */
float Pasture3DWaterFFT::get_height_sigma() const {
	if (!_sigma_dirty) {
		return _sigma;
	}
	static constexpr int LOW_RING = 16;
	SeaTerms terms;
	terms.g = GRAVITY;
	terms.depth = MAX(_depth, 0.01f);
	const Vector4 lo = get_band_low();
	const Vector4 hi = get_band_high();
	const int steps = 2000;
	double total = 0.0;
	const int displacing = get_displacing_mask();
	for (int c = 0; c < CASCADES; c++) {
		if (!(displacing & (1 << c))) {
			continue;
		}
		const double dk = Math_TAU / MAX(_cascade_lengths[c], 0.01f);
		const double k_ring = LOW_RING * dk;
		const double k_max = MIN(0.5 * _resolution * dk, (double)hi[c]);
		PackedFloat32Array sp[2] = { get_spectrum_params(2 * c), get_spectrum_params(2 * c + 1) };
		const int pair = sp[1][0] > 0.f ? 2 : 1;
		// The low rings, mode by mode.
		for (int iy = -LOW_RING; iy <= LOW_RING; iy++) {
			for (int ix = -LOW_RING; ix <= LOW_RING; ix++) {
				const double kx = ix * dk;
				const double ky = iy * dk;
				const double k = std::sqrt(kx * kx + ky * ky);
				if (k <= 0.0 || k >= k_ring || k < lo[c] || k >= k_max) {
					continue;
				}
				double omega, domega, tma;
				terms.dispersion(k, omega, domega, tma);
				const double theta = std::atan2(ky, kx);
				double psi = 0.0;
				for (int si = 0; si < pair; si++) {
					const float *p = sp[si].ptr();
					psi += SeaTerms::radial(p, k, omega, tma, terms.g) * SeaTerms::spread(p, theta, omega);
				}
				total += psi * domega / k * dk * dk;
			}
		}
		// The rest, as a 1D integral.
		const double k0 = MAX(k_ring, (double)lo[c]);
		if (k_max <= k0) {
			continue;
		}
		double prev_k = k0;
		double prev_f = 0.0;
		for (int i = 0; i <= steps; i++) {
			const double k = k0 * std::pow(k_max / k0, (double)i / steps);
			double omega, domega, tma;
			terms.dispersion(k, omega, domega, tma);
			double f = 0.0;
			for (int si = 0; si < pair; si++) {
				const float *p = sp[si].ptr();
				f += SeaTerms::radial(p, k, omega, tma, terms.g) * (2.0 - CLAMP((double)p[2], 0.0, 1.0));
			}
			f *= domega;
			if (i > 0) {
				total += 0.5 * (f + prev_f) * (k - prev_k);
			}
			prev_k = k;
			prev_f = f;
		}
	}
	_sigma = (float)std::sqrt(MAX(8.0 * total, 0.0));
	_sigma_dirty = false;
	return _sigma;
}

float Pasture3DWaterFFT::get_variance_wavelength(const float p_fraction) const {
	SeaTerms terms;
	terms.g = GRAVITY;
	terms.depth = MAX(_depth, 0.01f);
	const Vector4 lo = get_band_low();
	const Vector4 hi = get_band_high();
	const int displacing = get_displacing_mask();
	// One log-spaced k axis spanning every displacing cascade's band; each cascade adds only inside its own.
	double k_lo = 0.0;
	double k_hi = 0.0;
	for (int c = 0; c < CASCADES; c++) {
		if (!(displacing & (1 << c))) {
			continue;
		}
		const double dk = Math_TAU / MAX(_cascade_lengths[c], 0.01f);
		const double a = MAX(dk, (double)lo[c]);
		const double b = MIN(0.5 * _resolution * dk, (double)hi[c]);
		if (b <= a) {
			continue;
		}
		k_lo = k_lo > 0.0 ? MIN(k_lo, a) : a;
		k_hi = MAX(k_hi, b);
	}
	if (k_hi <= k_lo) {
		return 0.f;
	}
	static constexpr int STEPS = 4000;
	std::vector<double> cumulative(STEPS + 1, 0.0);
	double total = 0.0;
	double prev_k = k_lo;
	double prev_f = 0.0;
	for (int i = 0; i <= STEPS; i++) {
		const double k = k_lo * std::pow(k_hi / k_lo, (double)i / STEPS);
		double omega, domega, tma;
		terms.dispersion(k, omega, domega, tma);
		double f = 0.0;
		for (int c = 0; c < CASCADES; c++) {
			if (!(displacing & (1 << c))) {
				continue;
			}
			const double dk = Math_TAU / MAX(_cascade_lengths[c], 0.01f);
			if (k < MAX(dk, (double)lo[c]) || k > MIN(0.5 * _resolution * dk, (double)hi[c])) {
				continue;
			}
			for (int si = 2 * c; si < 2 * c + 2; si++) {
				const PackedFloat32Array sp = get_spectrum_params(si);
				const float *p = sp.ptr();
				if (p[0] <= 0.f) {
					continue;
				}
				f += SeaTerms::radial(p, k, omega, tma, terms.g) * (2.0 - CLAMP((double)p[2], 0.0, 1.0));
			}
		}
		f *= domega;
		if (i > 0) {
			total += 0.5 * (f + prev_f) * (k - prev_k);
		}
		cumulative[i] = total;
		prev_k = k;
		prev_f = f;
	}
	if (total <= 0.0) {
		return 0.f;
	}
	// Variance accumulates from the long waves down, so the first k past the fraction is the wavelength.
	const double target = CLAMP((double)p_fraction, 0.0, 1.0) * total;
	for (int i = 1; i <= STEPS; i++) {
		if (cumulative[i] >= target) {
			const double k0 = k_lo * std::pow(k_hi / k_lo, (double)(i - 1) / STEPS);
			const double k1 = k_lo * std::pow(k_hi / k_lo, (double)i / STEPS);
			const double span = cumulative[i] - cumulative[i - 1];
			const double t = span > 0.0 ? (target - cumulative[i - 1]) / span : 0.0;
			return (float)(Math_TAU / (k0 + t * (k1 - k0)));
		}
	}
	return (float)(Math_TAU / k_hi);
}

void Pasture3DWaterFFT::set_spectrum_knob(const int p_spectrum, const StringName &p_knob, const float p_value) {
	ERR_FAIL_INDEX(p_spectrum, SPECTRA);
	float *v = knob_ptr(_spectra[p_spectrum], p_knob);
	ERR_FAIL_NULL_MSG(v, vformat("Unknown spectrum knob '%s'", String(p_knob)));
	if (*v == p_value) {
		return;
	}
	*v = p_value;
	_knob_changed(true);
}

float Pasture3DWaterFFT::get_spectrum_knob(const int p_spectrum, const StringName &p_knob) const {
	ERR_FAIL_INDEX_V(p_spectrum, SPECTRA, 0.f);
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

// The eight spectra's knobs as "spectrum_1/<knob>" .. "spectrum_8/<knob>", the reference's spectrum1..8
// (index 0..7 in set_spectrum_knob). Dynamic rather than 64 bound setters, because they are one struct
// eight times and the knob names are already the API.
static const char *SPECTRUM_PREFIX = "spectrum_";
static const char *SPECTRUM_KNOBS[] = { "scale", "wind_speed", "direction_deg", "fetch", "spread_blend", "swell",
	"peak_enhancement", "short_waves_fade" };
static const char *SPECTRUM_HINTS[] = { "0,4,0.01,or_greater", "0.1,40,0.1,suffix:m/s", "-360,360,0.5,degrees",
	"10,100000000,10,exp,suffix:m", "0,1,0.01", "0,1,0.01", "1,10,0.01", "0,1,0.001,suffix:m" };

static bool split_spectrum_name(const StringName &p_name, int &r_spectrum, StringName &r_knob) {
	String n = p_name;
	if (!n.begins_with(SPECTRUM_PREFIX)) {
		return false;
	}
	const int start = String(SPECTRUM_PREFIX).length();
	const int slash = n.find("/");
	if (slash < 0) {
		return false;
	}
	const String number = n.substr(start, slash - start);
	if (!number.is_valid_int()) {
		return false;
	}
	r_spectrum = number.to_int() - 1;
	r_knob = n.substr(slash + 1);
	return r_spectrum >= 0 && r_spectrum < Pasture3DWaterFFT::SPECTRA;
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
	for (int i = 0; i < SPECTRA; i++) {
		for (int k = 0; k < 8; k++) {
			p_list->push_back(PropertyInfo(Variant::FLOAT, vformat("%s%d/%s", SPECTRUM_PREFIX, i + 1, SPECTRUM_KNOBS[k]),
					PROPERTY_HINT_RANGE, SPECTRUM_HINTS[k]));
		}
	}
}

void Pasture3DWaterFFT::_bind_methods() {
	BIND_ENUM_CONSTANT(OUTPUT_INITIAL_SPECTRUM);
	BIND_ENUM_CONSTANT(OUTPUT_SPECTRUM);
	BIND_ENUM_CONSTANT(OUTPUT_DISPLACEMENT);
	BIND_ENUM_CONSTANT(OUTPUT_SLOPE);
	BIND_CONSTANT(READBACK_KEEPALIVE);
	BIND_CONSTANT(SPECTRA);

	ClassDB::bind_static_method("Pasture3DWaterFFT", D_METHOD("is_supported"), &Pasture3DWaterFFT::is_supported);
	ClassDB::bind_static_method("Pasture3DWaterFFT", D_METHOD("snap_resolution", "resolution"), &Pasture3DWaterFFT::snap_resolution);
	ClassDB::bind_static_method("Pasture3DWaterFFT", D_METHOD("resolution_for_limits", "requested", "shared_bytes", "invocations", "size_x"),
			&Pasture3DWaterFFT::resolution_for_limits);
	ClassDB::bind_static_method("Pasture3DWaterFFT", D_METHOD("get_max_resolution"), &Pasture3DWaterFFT::get_max_resolution);
	ClassDB::bind_method(D_METHOD("is_available"), &Pasture3DWaterFFT::is_available);
	ClassDB::bind_method(D_METHOD("update", "time", "delta"), &Pasture3DWaterFFT::update);
	ClassDB::bind_method(D_METHOD("get_update_count"), &Pasture3DWaterFFT::get_update_count);
	ClassDB::bind_method(D_METHOD("get_texture_generation"), &Pasture3DWaterFFT::get_texture_generation);
	ClassDB::bind_method(D_METHOD("get_displacement_texture"), &Pasture3DWaterFFT::get_displacement_texture);
	ClassDB::bind_method(D_METHOD("get_slope_texture"), &Pasture3DWaterFFT::get_slope_texture);
	ClassDB::bind_method(D_METHOD("get_band_low"), &Pasture3DWaterFFT::get_band_low);
	ClassDB::bind_method(D_METHOD("get_band_high"), &Pasture3DWaterFFT::get_band_high);
	ClassDB::bind_method(D_METHOD("read_layer", "output", "layer", "mip"), &Pasture3DWaterFFT::read_layer, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("request_cpu_surface"), &Pasture3DWaterFFT::request_cpu_surface);
	ClassDB::bind_method(D_METHOD("get_readback_count"), &Pasture3DWaterFFT::get_readback_count);
	ClassDB::bind_method(D_METHOD("get_readback_update"), &Pasture3DWaterFFT::get_readback_update);
	ClassDB::bind_method(D_METHOD("get_readback_time"), &Pasture3DWaterFFT::get_readback_time);
	ClassDB::bind_method(D_METHOD("sample_cpu_displacement", "domain_xz"), &Pasture3DWaterFFT::sample_cpu_displacement);
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
	ClassDB::bind_method(D_METHOD("set_cascade_tiles", "tiles"), &Pasture3DWaterFFT::set_cascade_tiles);
	ClassDB::bind_method(D_METHOD("get_cascade_tiles"), &Pasture3DWaterFFT::get_cascade_tiles);
	ClassDB::bind_method(D_METHOD("set_cascade_drawn", "mask"), &Pasture3DWaterFFT::set_cascade_drawn);
	ClassDB::bind_method(D_METHOD("get_cascade_drawn"), &Pasture3DWaterFFT::get_cascade_drawn);
	ClassDB::bind_method(D_METHOD("set_cascade_displaces", "mask"), &Pasture3DWaterFFT::set_cascade_displaces);
	ClassDB::bind_method(D_METHOD("get_cascade_displaces"), &Pasture3DWaterFFT::get_cascade_displaces);
	ClassDB::bind_method(D_METHOD("set_cascade_foam_offset", "offset"), &Pasture3DWaterFFT::set_cascade_foam_offset);
	ClassDB::bind_method(D_METHOD("get_cascade_foam_offset"), &Pasture3DWaterFFT::get_cascade_foam_offset);
	ClassDB::bind_method(D_METHOD("get_cascade_repeats"), &Pasture3DWaterFFT::get_cascade_repeats);
	ClassDB::bind_method(D_METHOD("get_displacing_mask"), &Pasture3DWaterFFT::get_displacing_mask);
	ClassDB::bind_method(D_METHOD("get_foam_offset_sum"), &Pasture3DWaterFFT::get_foam_offset_sum);
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
	ClassDB::bind_method(D_METHOD("get_variance_wavelength", "fraction"), &Pasture3DWaterFFT::get_variance_wavelength);

	// Manager-driven: bound so a gate can drive a standalone simulation, never stored.
	ADD_PROPERTY(PropertyInfo(Variant::INT, "resolution", PROPERTY_HINT_ENUM, "128:128,256:256,512:512,1024:1024", PROPERTY_USAGE_NONE), "set_resolution", "get_resolution");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "seed"), "set_seed", "get_seed");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "depth", PROPERTY_HINT_RANGE, "0.1,500.0,0.1,or_greater,suffix:m"), "set_depth", "get_depth");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "choppiness", PROPERTY_HINT_RANGE, "0.0,3.0,0.01"), "set_choppiness", "get_choppiness");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "loop_period", PROPERTY_HINT_RANGE, "1.0,600.0,0.1,suffix:s", PROPERTY_USAGE_NONE), "set_loop_period", "get_loop_period");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR4, "cascade_lengths", PROPERTY_HINT_NONE, "suffix:m"), "set_cascade_lengths", "get_cascade_lengths");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR4, "cascade_tiles", PROPERTY_HINT_NONE, "suffix:m"), "set_cascade_tiles", "get_cascade_tiles");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "cascade_drawn", PROPERTY_HINT_FLAGS, "Cascade 1,Cascade 2,Cascade 3,Cascade 4"), "set_cascade_drawn", "get_cascade_drawn");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "cascade_displaces", PROPERTY_HINT_FLAGS, "Cascade 1,Cascade 2,Cascade 3,Cascade 4"), "set_cascade_displaces", "get_cascade_displaces");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR4, "cascade_foam_offset"), "set_cascade_foam_offset", "get_cascade_foam_offset");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "band_limited"), "set_band_limited", "get_band_limited");
	ADD_GROUP("Foam", "foam_");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "foam_bias", PROPERTY_HINT_RANGE, "-2.0,2.0,0.01"), "set_foam_bias", "get_foam_bias");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "foam_threshold", PROPERTY_HINT_RANGE, "-10.0,10.0,0.01"), "set_foam_threshold", "get_foam_threshold");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "foam_add", PROPERTY_HINT_RANGE, "0.0,60.0,0.01,suffix:/s"), "set_foam_add", "get_foam_add");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "foam_decay", PROPERTY_HINT_RANGE, "0.0,60.0,0.01,suffix:/s"), "set_foam_decay", "get_foam_decay");
}
