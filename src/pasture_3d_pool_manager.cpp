// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "logger.h"
#include "pasture_3d_ocean.h"
#include "pasture_3d.h"
#include "pasture_3d_material.h"
#include "pasture_3d_pool_manager.h"

///////////////////////////
// Private Functions
///////////////////////////

/**
 * Cache key for one (base material, profile) pair.
 *
 * Keyed on the base's INSTANCE ID and not its resource path, because the base is
 * frequently pathless: a material the user made unique into the scene, or one built
 * in code by a test, has no path at all and every one of them would collide on "".
 */
String Pasture3DPoolManager::_cache_key(const Ref<Material> &p_base, const StringName &p_profile) const {
	uint64_t id = p_base.is_valid() ? (uint64_t)p_base->get_instance_id() : 0;
	return String::num_uint64(id) + "|" + String(p_profile);
}

/**
 * Writes a profile's model into one material.
 *
 * Only ShaderMaterial carries the uniforms; anything else is left alone rather than
 * refused. A user is allowed to put a StandardMaterial3D on a pool -- it will not be
 * water, and Pasture3DPool warns about it in Phase 3 -- but it must not error here every
 * frame.
 */
void Pasture3DPoolManager::_upload_into(const Ref<Material> &p_material, const Ref<Pasture3DWaveProfile> &p_profile) {
	ShaderMaterial *mat = Object::cast_to<ShaderMaterial>(p_material.ptr());
	if (!mat || p_profile.is_null()) {
		return;
	}
	// The period is the manager's, not the profile's (§5.3). The FFT quantises its dispersion and the fBm
	// its speeds to a whole number of cycles in it, which is what makes the clock's wrap seamless.
	p_profile->set_loop_period(_loop_period);
	// The model is a uniform branch, not a variant (FFT spec §3), so switching costs a write here and no
	// shader swap on any cached material.
	Ref<Pasture3DWaterFFT> fft = p_profile->get_fft();
	Ref<Pasture3DWaterFBM> fbm = p_profile->get_fbm();
	if (p_profile->is_fbm_active()) {
		mat->set_shader_parameter("_wave_model", SHADER_MODEL_FBM);
		static const char *names[2][4] = { { "_fbm_v0", "_fbm_v1", "_fbm_v2", "_fbm_v3" },
			{ "_fbm_f0", "_fbm_f1", "_fbm_f2", "_fbm_f3" } };
		for (int set = 0; set < 2; set++) {
			PackedVector4Array pack = fbm->get_shader_pack(set);
			for (int i = 0; i < 4; i++) {
				mat->set_shader_parameter(names[set][i], pack[i]);
			}
		}
	} else if (p_profile->is_fft_active()) {
		mat->set_shader_parameter("_wave_model", SHADER_MODEL_FFT);
		// The Texture2DArrayRD wrappers, not their RIDs: the simulation builds its GPU textures lazily on
		// the render thread, and a wrapper hands the material a placeholder until then that
		// set_texture_rd_rid() later replaces in place. Uploading before the first tick is therefore fine.
		mat->set_shader_parameter("_fft_displacement", fft->get_displacement_texture());
		mat->set_shader_parameter("_fft_slope", fft->get_slope_texture());
		mat->set_shader_parameter("_fft_repeat", fft->get_cascade_repeats());
		Vector4 drawn;
		Vector4 displaces;
		for (int i = 0; i < Pasture3DWaterFFT::CASCADES; i++) {
			drawn[i] = (fft->get_cascade_drawn() >> i) & 1 ? 1.f : 0.f;
			displaces[i] = (fft->get_displacing_mask() >> i) & 1 ? 1.f : 0.f;
		}
		mat->set_shader_parameter("_fft_drawn", drawn);
		mat->set_shader_parameter("_fft_displaces", displaces);
		mat->set_shader_parameter("_fft_foam_offset", fft->get_foam_offset_sum());
		const int at = _live_ffts.find(fft);
		if (at < 0) {
			_live_ffts.push_back(fft);
			_live_fft_generations.push_back(fft->get_texture_generation());
		}
	} else {
		// No knobs for either model: the FFT branch over unbound textures, which read black, is flat.
		mat->set_shader_parameter("_wave_model", SHADER_MODEL_FFT);
		mat->set_shader_parameter("_fft_displacement", Variant());
		mat->set_shader_parameter("_fft_slope", Variant());
	}
	_upload_count++;
}

/**
 * Tells every profile which model its materials draw, and at what resolution.
 *
 * Called whenever the answer could have moved: the setting, the resolution, or the profile set itself.
 */
void Pasture3DPoolManager::_apply_model_to_profiles() {
	const WaveModel model = get_effective_wave_model();
	const int resolution = get_effective_fft_resolution();
	if (is_wave_model_fallback() && !_fallback_warned) {
		_fallback_warned = true;
		LOG(WARN, "FFT waves need a RenderingDevice (Forward+ or Mobile) and this renderer has none; ",
				"drawing the fBm fallback instead");
	}
	if (is_fbm_by_choice() && !_choice_warned) {
		_choice_warned = true;
		LOG(WARN, FBM_CHOICE_WARNING);
	}
	const int shader_model = model == WAVE_MODEL_FFT ? SHADER_MODEL_FFT : SHADER_MODEL_FBM;
	// The built-ins too, overridden or not: one a scene stops overriding is drawn at once.
	TypedArray<Pasture3DWaveProfile> all = _profiles.duplicate();
	all.append_array(_builtin_profiles);
	for (int i = 0; i < all.size(); i++) {
		Ref<Pasture3DWaveProfile> profile = all[i];
		if (profile.is_null()) {
			continue;
		}
		if (profile->get_fft().is_valid()) {
			profile->get_fft()->set_resolution(resolution);
		}
		profile->set_active_model(shader_model);
	}
	_applied_model = model;
	_applied_resolution = resolution;
}

/**
 * ProjectSettings.settings_changed. Fires for ANY setting, deferred, so this only acts when the effective
 * answer moved. WaterFBMGate [P] checks that a runtime set_setting() reaches here.
 */
void Pasture3DPoolManager::_on_project_settings_changed() {
	const int model = get_effective_wave_model();
	const int resolution = get_effective_fft_resolution();
	if (model == _applied_model && resolution == _applied_resolution) {
		return;
	}
	const bool model_moved = model != _applied_model;
	_apply_model_to_profiles();
	if (model_moved) {
		rebuild_tables();
	} else {
		// As set_fft_resolution(): the simulations rebuild in place, only the cull bounds move.
		emit_signal("profiles_changed");
	}
	update_configuration_warnings();
}

/**
 * Advances every live simulation to the shared clock.
 *
 * Per RENDERED frame, from NOTIFICATION_PROCESS, not per physics tick: the result is a texture the next
 * draw samples, so ticking at the physics rate would compute frames nobody sees at 30 fps, and repeat
 * one at 144. The clock itself still advances at the physics rate, and this reads whatever it reached.
 *
 * Paused, the surface holds still and the foam stops decaying with it: dt is 0, not the frame time.
 */
void Pasture3DPoolManager::_tick_ffts(const double p_delta) {
	if (_live_ffts.is_empty() || !is_fft_effective()) {
		return;
	}
	const float dt = _paused ? 0.f : (float)p_delta;
	// A simulation that built new textures since the last look (its first build, or a resolution change)
	// leaves every material bound before it holding the default black array: see
	// Pasture3DWaterFFT::get_texture_generation(). Re-uploading re-sets the parameter, which binds the real
	// texture. NOT profiles_changed: a body with auto spacing re-meshes on that, and nothing about the
	// geometry moved. wave_textures_changed tells the holders of private duplicates (the ocean, a masked
	// pool) to re-upload theirs. Checked BEFORE this frame's dispatch, so a build queued last frame on the
	// render thread has landed.
	bool rebind = false;
	for (int i = 0; i < _live_ffts.size(); i++) {
		const Ref<Pasture3DWaterFFT> &fft = _live_ffts[i];
		if (fft.is_valid() && fft->get_texture_generation() != _live_fft_generations[i]) {
			_live_fft_generations.write[i] = fft->get_texture_generation();
			rebind = true;
		}
	}
	if (rebind) {
		_rebind_count++;
		_reupload_cache();
		emit_signal("wave_textures_changed");
	}
	for (const Ref<Pasture3DWaterFFT> &fft : _live_ffts) {
		if (fft.is_valid()) {
			fft->set_loop_period((float)_loop_period);
			fft->update((float)_water_time, dt);
			_fft_tick_count++;
		}
	}
}

/**
 * Declares the water globals at runtime if project.godot did not.
 *
 * Moved verbatim from Pasture3D::_register_water_globals() in Phase 2. The editor
 * plugin persists these to project.godot, which is what makes them exist at engine
 * startup and therefore resolve in exported builds; this is the fallback for the
 * first run after enabling the plugin, and for projects where the settings were
 * never written.
 *
 * Phase 1 probes of the water shader work established the rules:
 *   - ProjectSettings::has_setting() is the only runtime-safe existence check.
 *     global_shader_parameter_get_list() and _get() are editor-only and error out
 *     in a game build.
 *   - Writing ProjectSettings at runtime does NOT register with RenderingServer;
 *     its global table is built from project.godot at startup and only then.
 */
void Pasture3DPoolManager::register_water_globals() {
	// Process-global, not per-node: the RenderingServer table is shared, so a
	// second manager (or an ocean) must not try to add what the first already did.
	static bool s_registered = false;
	if (s_registered) {
		return;
	}
	s_registered = true;
	// The water terrain check (water_terrain.gdshaderinc) reads the terrain's globals; they must exist before
	// a water material compiles even in a scene with no terrain, where nothing else would declare them.
	Pasture3DMaterial::register_terrain_globals();

	struct GlobalDecl {
		const char *name;
		RenderingServer::GlobalShaderParameterType type;
		Variant initial;
	};
	const GlobalDecl decls[] = {
		{ "water_time", RenderingServer::GLOBAL_VAR_TYPE_FLOAT, 0.0f },
		{ "water_sun_direction", RenderingServer::GLOBAL_VAR_TYPE_VEC3, Vector3(0.f, -1.f, 0.f) },
		{ "water_sun_color", RenderingServer::GLOBAL_VAR_TYPE_VEC3, Vector3(1.f, 1.f, 1.f) },
		// The clock's wrap period. The shader needs it, not just the clock:
		// anything else that advances with water_time -- the scrolling detail
		// texture -- has to quantise its own rate to the same loop or the wrap that
		// is seamless for the waves is a visible jump for the ripples.
		{ "water_time_period", RenderingServer::GLOBAL_VAR_TYPE_FLOAT, 120.0f },
	};
	ProjectSettings *settings = ProjectSettings::get_singleton();
	for (const GlobalDecl &decl : decls) {
		if (settings && settings->has_setting(String("shader_globals/") + decl.name)) {
			continue;
		}
		// No LOG here: this is a static member and the LOG macro reaches for the
		// instance's __class__.
		RS->global_shader_parameter_add(decl.name, decl.type, decl.initial);
	}
}

/**
 * The two water settings a game's options menu writes (FFT spec §4).
 *
 * Registered with their initial values so the Project Settings UI shows them and project.godot only
 * stores them once someone moves them -- Pasture3DData::_register_threshold's pattern.
 */
void Pasture3DPoolManager::register_water_settings() {
	ProjectSettings *ps = ProjectSettings::get_singleton();
	if (!ps) {
		return;
	}
	struct SettingDecl {
		const char *name;
		int initial;
		const char *hint;
	};
	const SettingDecl decls[] = {
		{ SETTING_WAVE_MODEL, 0, "FFT,fBm" },
		{ SETTING_FFT_RESOLUTION, 256, "128:128,256:256,512:512,1024:1024" },
	};
	for (const SettingDecl &decl : decls) {
		if (!ps->has_setting(decl.name)) {
			ps->set_setting(decl.name, decl.initial);
		}
		ps->set_initial_value(decl.name, decl.initial);
		Dictionary info;
		info["name"] = decl.name;
		info["type"] = Variant::INT;
		info["hint"] = PROPERTY_HINT_ENUM;
		info["hint_string"] = decl.hint;
		ps->add_property_info(info);
	}
}

bool Pasture3DPoolManager::is_plugin_written_param(const StringName &p_name) {
	// The `_` prefix is this codebase's existing marker for a uniform the plugin fills
	// in rather than one the artist sets -- _wave_model, _fft_repeat, _mesh_size, _subdiv,
	// _vertex_spacing, _target_pos, _water_domain_origin all carry it, in the water
	// shaders and in the legacy one alike. The exception is named as an art knob
	// because it reads as one, but the ocean owns it.
	return String(p_name).begins_with("_") || p_name == StringName("sea_level");
}

bool Pasture3DPoolManager::sync_material_params(const Ref<Material> &p_base, const Ref<Material> &p_target) {
	ShaderMaterial *base = Object::cast_to<ShaderMaterial>(p_base.ptr());
	ShaderMaterial *target = Object::cast_to<ShaderMaterial>(p_target.ptr());
	if (!base || !target || base == target) {
		return false;
	}
	bool wrote = false;
	// The SHADER can change under the material too -- dropping a different .gdshader on
	// a preset is how someone moves a body between tiers -- and a target still
	// compiling the old one would silently ignore every uniform copied below.
	Ref<Shader> shader = base->get_shader();
	if (target->get_shader() != shader) {
		target->set_shader(shader);
		wrote = true;
	}
	if (target->get_render_priority() != base->get_render_priority()) {
		target->set_render_priority(base->get_render_priority());
		wrote = true;
	}
	if (target->get_next_pass() != base->get_next_pass()) {
		target->set_next_pass(base->get_next_pass());
		wrote = true;
	}
	if (shader.is_null()) {
		return wrote;
	}
	// Driven off the SHADER's uniform list rather than the base's property list: a
	// parameter the base leaves at its shader default is absent from the base's own
	// storage but may well be set on the target from an earlier sync, and only walking
	// every uniform clears it back. get_shader_parameter() returns nil for an unset one,
	// and setting nil is how a ShaderMaterial spells "use the shader's default".
	Array uniforms = shader->get_shader_uniform_list();
	for (int i = 0; i < uniforms.size(); i++) {
		Dictionary uniform = uniforms[i];
		StringName name = uniform.get("name", StringName());
		if (String(name).is_empty() || is_plugin_written_param(name)) {
			continue;
		}
		Variant value = base->get_shader_parameter(name);
		// Compared before writing, because this is polled: an untouched material must
		// cost reads and no RenderingServer traffic at all.
		if (target->get_shader_parameter(name) != value) {
			target->set_shader_parameter(name, value);
			wrote = true;
		}
	}
	return wrote;
}

void Pasture3DPoolManager::upload_profile_into(const Ref<Material> &p_material, const StringName &p_profile) {
	_upload_into(p_material, get_profile(p_profile));
}

/**
 * Carries inspector edits of a base material into the duplicates handed out from it.
 *
 * Polled, and polled over every cached pair rather than over the one that moved, because
 * nothing announces a shader parameter change -- see sync_material_params(). Bounded by
 * the number of distinct (base, profile) pairs in the scene, not by the number of
 * bodies, which is the same bound _on_profile_changed works to.
 *
 * EDITOR ONLY. This exists so a slider drag shows up on the water; a running game
 * assigns materials, it does not tune them, and paying a per-frame walk of every uniform
 * for that would be a poll nobody asked for.
 */
void Pasture3DPoolManager::_poll_base_materials() {
	for (const KeyValue<String, CachedMaterial> &kv : _material_cache) {
		sync_material_params(kv.value.base, kv.value.shared);
	}
}

void Pasture3DPoolManager::_reupload_cache() {
	for (const KeyValue<String, CachedMaterial> &kv : _material_cache) {
		_upload_into(kv.value.shared, get_profile(kv.value.profile));
	}
}

void Pasture3DPoolManager::_on_profile_changed() {
	// A knob moved. Every cached material carrying that profile is now stale --
	// and rather than work out which, re-upload all of them: the cache holds one
	// material per pair, so this is bounded by the number of distinct pairs in the
	// scene, not by the number of bodies. Ten ponds is still one upload.
	_reupload_cache();
	// Bodies outside the cache (Pasture3DOcean holds a private material, §6) have no other
	// way to learn a knob moved.
	emit_signal("profiles_changed");
}

void Pasture3DPoolManager::_connect_profiles() {
	_apply_model_to_profiles();
	Callable cb = callable_mp(this, &Pasture3DPoolManager::_on_profile_changed);
	TypedArray<Pasture3DWaveProfile> all = _profiles.duplicate();
	all.append_array(_builtin_profiles);
	for (int i = 0; i < all.size(); i++) {
		Ref<Pasture3DWaveProfile> profile = all[i];
		if (profile.is_null()) {
			continue;
		}
		profile->set_loop_period(_loop_period);
		if (!profile->is_connected("changed", cb)) {
			profile->connect("changed", cb);
		}
	}
}

/**
 * Advances the shared clock and wraps it to the loop period.
 *
 * Lifted from Pasture3D::_update_water_clock() with one change: the period is the
 * manager's own rather than the ocean wave table's. Everything else -- the wrap, the
 * change-detected period write, the reason the clock is bounded at all (water spec
 * §3.2) -- is the same and is documented there.
 */
void Pasture3DPoolManager::_update_clock(const double p_delta) {
	if (!_paused) {
		_water_time += p_delta;
	}
	double period = (double)_loop_period;
	if (period > 0.0) {
		_water_time = Math::fposmod(_water_time, period);
	}
	RS->global_shader_parameter_set("water_time", (float)_water_time);
	if (_period_sent != (float)period) {
		_period_sent = (float)period;
		RS->global_shader_parameter_set("water_time_period", (float)period);
	}
}

void Pasture3DPoolManager::_update_sun() {
	DirectionalLight3D *light = Object::cast_to<DirectionalLight3D>(_sun_light.ptr());
	if (!light) {
		return;
	}
	// The light's +Z basis column points FROM the surface TOWARD the sun, so
	// water_sun_direction.y > 0 is daytime. Same convention as the ocean's, and as
	// water_common.gdshaderinc documents.
	Vector3 direction = light->get_global_basis().get_column(2);
	Color c = light->get_color() * light->get_param(DirectionalLight3D::PARAM_ENERGY);
	Vector3 color(c.r, c.g, c.b);
	if (direction != _sun_dir_sent) {
		_sun_dir_sent = direction;
		RS->global_shader_parameter_set("water_sun_direction", direction);
	}
	if (color != _sun_color_sent) {
		_sun_color_sent = color;
		RS->global_shader_parameter_set("water_sun_color", color);
	}
}

/**
 * Fills _builtin_profiles with the four shipped sea states (spec §5.2, PASTURE3D_WATER_REFERENCE_SPEC.md §5).
 *
 *   ocean_default  the reference's sea, exactly, a new Pasture3DWaveProfile, but for its foam_lift (W3).
 *   lake_calm      the reference's sea scaled to a 25 m longest wave, and pond_still to 12 m
 *   pond_still     (fit_reference_sea): lower wind, shorter fetch, smaller cascades and shallower
 *                  water, all by one Froude scaling, so each is the reference's sea seen smaller and
 *                  its height scales with it. The sizes are the Gerstner presets' longest waves.
 *   river_flow     chop aligned to a flow direction, fit_sea() of the retired river preset. A river's
 *                  material does not draw it (water_stream.gdshaderinc replaces the wave model); a
 *                  Pasture3DStream reads it for its buoyancy and its mesh density, so its
 *                  min_wavelength stays the retired table's shortest wave rather than the FFT's.
 *
 * WaterRetireGerstnerGate [P] checks these against the same calls, so the two cannot drift apart.
 *
 * BUILT-INS, NOT A PROPERTY DEFAULT (production spec §2.1). These used to seed `profiles` itself, and
 * an array of fresh resources never equals the default, so every scene saved all four. A saved copy
 * then shadowed every later retune: sculpting_2's lake drew the reference ocean's spectrum on lake-sized
 * cascades long after R5 had refitted the preset. Now a scene names a built-in and gets the current one;
 * to keep its own, it overrides it explicitly (override_builtin()).
 */
void Pasture3DPoolManager::_seed_builtin_profiles() {
	Ref<Pasture3DWaveProfile> ocean;
	ocean.instantiate();
	ocean->set_profile_name("ocean_default");
	// Ours, on the reference's offsets (production spec W3): its crests make next to no foam. 0.25 at 1024
	// is the look chosen by eye at 256, where the shader's resolution lift adds 0.2 more.
	ocean->get_fft()->set_foam_lift(0.25f);
	_builtin_profiles.push_back(ocean);

	struct Scaled {
		const char *name;
		real_t direction_deg;
		real_t length_max; // metres
	};
	const Scaled scaled[] = {
		{ "lake_calm", 35.f, 25.f },
		{ "pond_still", 55.f, 12.f },
	};
	for (const Scaled &p : scaled) {
		Ref<Pasture3DWaveProfile> profile;
		profile.instantiate();
		profile->set_profile_name(p.name);
		profile->fit_reference_sea(p.direction_deg, p.length_max);
		_builtin_profiles.push_back(profile);
	}

	Ref<Pasture3DWaveProfile> river;
	river.instantiate();
	river->set_profile_name("river_flow");
	river->fit_sea(0.f, 10.f, 0.0236074f);
	river->set_min_wavelength(5.0084f);
	_builtin_profiles.push_back(river);
	_connect_profiles();
}

TypedArray<Pasture3DWaveProfile> Pasture3DPoolManager::_all_profiles() const {
	TypedArray<Pasture3DWaveProfile> all = _profiles.duplicate();
	for (int i = 0; i < _builtin_profiles.size(); i++) {
		Ref<Pasture3DWaveProfile> builtin = _builtin_profiles[i];
		bool overridden = false;
		for (int j = 0; j < _profiles.size(); j++) {
			Ref<Pasture3DWaveProfile> own = _profiles[j];
			if (own.is_valid() && own->get_profile_name() == builtin->get_profile_name()) {
				overridden = true;
				break;
			}
		}
		if (!overridden) {
			all.push_back(builtin);
		}
	}
	return all;
}

// Compares the STORAGE properties of two objects of one class, recursing into Object values.
static bool stored_properties_equal(Object *p_a, Object *p_b, const PackedStringArray &p_skip) {
	if (p_a == p_b) {
		return true;
	}
	if (!p_a || !p_b || p_a->get_class() != p_b->get_class()) {
		return false;
	}
	TypedArray<Dictionary> props = p_a->get_property_list();
	for (int i = 0; i < props.size(); i++) {
		Dictionary prop = props[i];
		if (!((int)prop["usage"] & PROPERTY_USAGE_STORAGE)) {
			continue;
		}
		String name = prop["name"];
		if (name == "script" || name.begins_with("resource_") || p_skip.has(name)) {
			continue;
		}
		Variant va = p_a->get(name);
		Variant vb = p_b->get(name);
		if (va.get_type() != vb.get_type()) {
			return false;
		}
		switch (va.get_type()) {
			case Variant::OBJECT: {
				// A nested resource compares by its own knobs, and never inherits the skip list.
				if (!stored_properties_equal((Object *)va, (Object *)vb, PackedStringArray())) {
					return false;
				}
			} break;
			case Variant::FLOAT: {
				if (!Math::is_equal_approx((double)va, (double)vb)) {
					return false;
				}
			} break;
			case Variant::VECTOR4: {
				if (!((Vector4)va).is_equal_approx((Vector4)vb)) {
					return false;
				}
			} break;
			default: {
				if (va != vb) {
					return false;
				}
			} break;
		}
	}
	return true;
}

bool Pasture3DPoolManager::profiles_store_same_knobs(const Ref<Pasture3DWaveProfile> &p_a,
		const Ref<Pasture3DWaveProfile> &p_b, const PackedStringArray &p_skip_fft) {
	if (p_a.is_null() || p_b.is_null()) {
		return p_a.is_null() && p_b.is_null();
	}
	PackedStringArray skip;
	skip.push_back("profile_name");
	skip.push_back("fft");
	if (!stored_properties_equal(p_a.ptr(), p_b.ptr(), skip)) {
		return false;
	}
	return stored_properties_equal(p_a->get_fft().ptr(), p_b->get_fft().ptr(), p_skip_fft);
}

/**
 * Drops the copies of built-ins that scenes saved while the built-ins were a property default.
 *
 * Three kinds go, each with a line in the output so the change is not silent:
 *   - a copy of the CURRENT built-in. It changes nothing today, and would shadow the next retune.
 *   - a copy of the retired Gerstner preset, saved before Phase 6: no FFT or fBm, only the old keys,
 *     holding exactly the values that preset seeded (RETIRED below; big_regions.tscn has all four).
 *     The legacy migration fits a real spectrum from them, so neither other test can see one.
 *   - a copy of the interim Gerstner-era fit: an FFT that stores nothing but cascade_lengths. Its other
 *     knobs fall to the class defaults, the reference ocean's, so it draws the ocean's spectrum on the
 *     cascades of a lake. That is what made sculpting_2's lake and pond race. Its fBm and min_wavelength
 *     are not compared: the interim fit derived them from the same lengths.
 * Anything else named like a built-in was tuned on purpose, and is kept as an override.
 *
 * Runs in set_profiles(), so it also sees a script's assignment. A script that builds a profile on
 * purpose fits it, which sets the spectrum, so it is never taken for the interim fit.
 */
TypedArray<Pasture3DWaveProfile> Pasture3DPoolManager::_drop_stale_builtin_copies(
		const TypedArray<Pasture3DWaveProfile> &p_profiles) const {
	// The Gerstner presets as _seed_default_profiles() made them until Phase 6 (f47e8f3e). The spread and
	// steepness are not kept by a profile, so they cannot be compared.
	struct Retired {
		const char *name;
		int count;
		real_t direction_deg;
		real_t amplitude;
		real_t length_max;
	};
	static const Retired RETIRED[] = {
		{ "ocean_default", 8, 20.f, 1.6f, 137.f },
		{ "lake_calm", 4, 35.f, 0.25f, 25.f },
		{ "pond_still", 2, 55.f, 0.05f, 12.f },
		{ "river_flow", 3, 0.f, 0.06f, 10.f },
	};
	Ref<Pasture3DWaterFFT> fresh_fft;
	fresh_fft.instantiate();
	PackedStringArray lengths_only;
	lengths_only.push_back("cascade_lengths");
	TypedArray<Pasture3DWaveProfile> kept;
	for (int i = 0; i < p_profiles.size(); i++) {
		Ref<Pasture3DWaveProfile> profile = p_profiles[i];
		if (profile.is_null() || !is_builtin_profile_name(profile->get_profile_name())) {
			kept.push_back(profile);
			continue;
		}
		const StringName name = profile->get_profile_name();
		Ref<Pasture3DWaveProfile> builtin;
		for (int j = 0; j < _builtin_profiles.size(); j++) {
			Ref<Pasture3DWaveProfile> b = _builtin_profiles[j];
			if (b->get_profile_name() == name) {
				builtin = b;
			}
		}
		if (profiles_store_same_knobs(profile, builtin)) {
			UtilityFunctions::print("Pasture3DPoolManager: '", name, "' was a saved copy of the built-in; using ",
					"the built-in. Save the scene to drop the copy.");
			continue;
		}
		bool retired = false;
		for (const Retired &r : RETIRED) {
			if (name == StringName(r.name) && profile->is_legacy_copy(r.count, r.direction_deg, r.amplitude, r.length_max)) {
				retired = true;
			}
		}
		if (retired) {
			UtilityFunctions::print("Pasture3DPoolManager: '", name, "' was a copy of the retired Gerstner preset; ",
					"using the built-in. Save the scene to drop the copy.");
			continue;
		}
		if (stored_properties_equal(profile->get_fft().ptr(), fresh_fft.ptr(), lengths_only)) {
			UtilityFunctions::print("Pasture3DPoolManager: '", name, "' was a stale copy of an old preset (it ",
					"stored only its cascade lengths, so it drew the ocean's spectrum); using the built-in. Save the ",
					"scene to drop the copy.");
			continue;
		}
		kept.push_back(profile);
	}
	return kept;
}

///////////////////////////
// Public Functions
///////////////////////////

Pasture3DPoolManager::Pasture3DPoolManager() {
	set_notify_transform(false);
	_seed_builtin_profiles();
}

Pasture3DPoolManager::~Pasture3DPoolManager() {
}

void Pasture3DPoolManager::set_profiles(const TypedArray<Pasture3DWaveProfile> &p_profiles) {
	// Disconnect the outgoing set first, or a profile removed from the array keeps
	// re-uploading into materials it no longer describes.
	Callable cb = callable_mp(this, &Pasture3DPoolManager::_on_profile_changed);
	for (int i = 0; i < _profiles.size(); i++) {
		Ref<Pasture3DWaveProfile> profile = _profiles[i];
		if (profile.is_valid() && profile->is_connected("changed", cb)) {
			profile->disconnect("changed", cb);
		}
	}
	_profiles = _drop_stale_builtin_copies(p_profiles);
	// Simulations of profiles that are gone would otherwise be ticked forever.
	_live_ffts.clear();
	_live_fft_generations.clear();
	_connect_profiles();
	// The set changed, so a cached material may now be carrying a table from a
	// profile that is gone. Rebuild rather than reason about it.
	rebuild_tables();
	update_configuration_warnings();
}

void Pasture3DPoolManager::set_loop_period(const real_t p_seconds) {
	real_t period = MAX(p_seconds, 0.1f);
	if (Math::is_equal_approx(_loop_period, period)) {
		return;
	}
	_loop_period = period;
	// Every table's frequency quantisation is against this number, so they are all
	// stale now. This is the one knob on this node that costs a full rebuild.
	rebuild_tables();
}

void Pasture3DPoolManager::set_sun_light(Node3D *p_light) {
	_sun_light.set_target(p_light);
	_sun_dir_sent = V3_MAX;
	_sun_color_sent = V3_MAX;
	update_configuration_warnings();
}

Pasture3DPoolManager::WaveModel Pasture3DPoolManager::_requested_wave_model() const {
	if (_wave_model != WAVE_MODEL_PROJECT) {
		return _wave_model;
	}
	ProjectSettings *ps = ProjectSettings::get_singleton();
	const int setting = ps ? (int)ps->get_setting(SETTING_WAVE_MODEL, 0) : 0;
	return setting == 1 ? WAVE_MODEL_FBM : WAVE_MODEL_FFT;
}

Pasture3DPoolManager::WaveModel Pasture3DPoolManager::get_effective_wave_model() const {
	const WaveModel model = _requested_wave_model();
	if (model == WAVE_MODEL_FFT && !Pasture3DWaterFFT::is_supported()) {
		return WAVE_MODEL_FBM;
	}
	return model;
}

bool Pasture3DPoolManager::is_wave_model_fallback() const {
	return _requested_wave_model() == WAVE_MODEL_FFT && !Pasture3DWaterFFT::is_supported();
}

bool Pasture3DPoolManager::is_fbm_by_choice() const {
	return _requested_wave_model() == WAVE_MODEL_FBM && Pasture3DWaterFFT::is_supported();
}

int Pasture3DPoolManager::_requested_fft_resolution() const {
	int r = _fft_resolution;
	if (r <= 0) {
		ProjectSettings *ps = ProjectSettings::get_singleton();
		r = ps ? (int)ps->get_setting(SETTING_FFT_RESOLUTION, 256) : 256;
	}
	return Pasture3DWaterFFT::snap_resolution(r);
}

int Pasture3DPoolManager::get_effective_fft_resolution() const {
	return MIN(_requested_fft_resolution(), Pasture3DWaterFFT::get_max_resolution());
}

void Pasture3DPoolManager::set_wave_model(const WaveModel p_model) {
	// 1 was Gerstner, retired in Phase 6 of the FFT port. A scene that asked for it gets the project's
	// choice, which is what a scene that asked for nothing gets.
	const WaveModel model = (p_model == WAVE_MODEL_FFT || p_model == WAVE_MODEL_FBM) ? p_model : WAVE_MODEL_PROJECT;
	if (_wave_model == model) {
		return;
	}
	_wave_model = model;
	_apply_model_to_profiles();
	rebuild_tables();
	update_configuration_warnings();
}

void Pasture3DPoolManager::set_fft_resolution(const int p_resolution) {
	// Stored as asked, so a scene keeps its 1024 on a machine that cannot run it; the effective resolution
	// falls back and the configuration warning says so.
	int r = p_resolution <= 0 ? 0 : Pasture3DWaterFFT::snap_resolution(p_resolution);
	if (_fft_resolution == r) {
		return;
	}
	_fft_resolution = r;
	update_configuration_warnings();
	// The simulations rebuild in place on their next tick and keep their texture RIDs, so no material
	// needs a re-upload; only the cull bounds, which read the spectrum's band, are refreshed.
	_apply_model_to_profiles();
	emit_signal("profiles_changed");
}

void Pasture3DPoolManager::set_paused(const bool p_paused) {
	_paused = p_paused;
}

Ref<Pasture3DWaveProfile> Pasture3DPoolManager::get_profile(const StringName &p_name) const {
	TypedArray<Pasture3DWaveProfile> all = _all_profiles();
	for (int i = 0; i < all.size(); i++) {
		Ref<Pasture3DWaveProfile> profile = all[i];
		if (profile.is_valid() && profile->get_profile_name() == p_name) {
			return profile;
		}
	}
	return Ref<Pasture3DWaveProfile>();
}

PackedStringArray Pasture3DPoolManager::get_profile_names() const {
	PackedStringArray names;
	TypedArray<Pasture3DWaveProfile> all = _all_profiles();
	for (int i = 0; i < all.size(); i++) {
		Ref<Pasture3DWaveProfile> profile = all[i];
		if (profile.is_valid()) {
			names.push_back(String(profile->get_profile_name()));
		}
	}
	return names;
}

PackedStringArray Pasture3DPoolManager::get_builtin_profile_names() const {
	PackedStringArray names;
	for (int i = 0; i < _builtin_profiles.size(); i++) {
		names.push_back(String(Ref<Pasture3DWaveProfile>(_builtin_profiles[i])->get_profile_name()));
	}
	return names;
}

bool Pasture3DPoolManager::is_builtin_profile_name(const StringName &p_name) const {
	return get_builtin_profile_names().has(String(p_name));
}

Ref<Pasture3DWaveProfile> Pasture3DPoolManager::override_builtin(const StringName &p_name) {
	for (int i = 0; i < _profiles.size(); i++) {
		Ref<Pasture3DWaveProfile> own = _profiles[i];
		if (own.is_valid() && own->get_profile_name() == p_name) {
			return own;
		}
	}
	for (int i = 0; i < _builtin_profiles.size(); i++) {
		Ref<Pasture3DWaveProfile> builtin = _builtin_profiles[i];
		if (builtin->get_profile_name() != p_name) {
			continue;
		}
		// Deep, so the copy's FFT and fBm are its own: tuning the override must not move the built-in.
		Ref<Pasture3DWaveProfile> copy = builtin->duplicate(true);
		// Not through set_profiles(): a fresh copy of the current built-in is exactly what its stale-copy
		// filter drops. The rest of what set_profiles() does, it does here.
		_profiles.push_back(copy);
		_live_ffts.clear();
		_live_fft_generations.clear();
		_connect_profiles();
		rebuild_tables();
		update_configuration_warnings();
		notify_property_list_changed();
		return copy;
	}
	LOG(WARN, "'", p_name, "' is not a built-in profile. Built-ins: ", String(", ").join(get_builtin_profile_names()));
	return Ref<Pasture3DWaveProfile>();
}

Ref<Material> Pasture3DPoolManager::get_material_for(const Ref<Material> &p_base, const StringName &p_profile) {
	if (p_base.is_null()) {
		return Ref<Material>();
	}
	Ref<Pasture3DWaveProfile> profile = get_profile(p_profile);
	if (profile.is_null()) {
		// An unresolved name is a configuration problem the body reports, not a
		// reason to hand back nothing: water with the material's own compile-time
		// default table is still water, and an invisible pool is a worse diagnostic
		// than a wrong-looking one.
		LOG(WARN, "No wave profile named '", String(p_profile), "'; returning the base material untouched");
		return p_base;
	}
	String key = _cache_key(p_base, p_profile);
	HashMap<String, CachedMaterial>::Iterator it = _material_cache.find(key);
	if (it) {
		return it->value.shared;
	}
	CachedMaterial entry;
	entry.base = p_base;
	entry.shared = p_base->duplicate();
	entry.profile = p_profile;
	_upload_into(entry.shared, profile);
	_material_cache.insert(key, entry);
	LOG(DEBUG, "Cached water material for key ", key, "; cache now holds ", _material_cache.size());
	return entry.shared;
}

void Pasture3DPoolManager::clear_material_cache() {
	_material_cache.clear();
}

void Pasture3DPoolManager::rebuild_tables() {
	TypedArray<Pasture3DWaveProfile> all = _profiles.duplicate();
	all.append_array(_builtin_profiles);
	for (int i = 0; i < all.size(); i++) {
		Ref<Pasture3DWaveProfile> profile = all[i];
		if (profile.is_valid()) {
			profile->set_loop_period(_loop_period);
		}
	}
	_on_profile_changed();
}

/**
 * Hands the current pair to one body, for a body that registered after the last camera change.
 *
 * The push/pull pair again, one level down: the manager pushes on change and a newcomer pulls on
 * arrival, so neither side needs to retry and a body added mid-game is not stuck on a single view.
 */
void Pasture3DPoolManager::_push_cameras_to_body(Node *p_body) {
	if (p_body && p_body->has_method("set_view_cameras")) {
		p_body->call("set_view_cameras", _view_cameras, _view_layers);
	}
}

void Pasture3DPoolManager::register_body(Node *p_body) {
	if (p_body && !_bodies.has(p_body)) {
		_bodies.push_back(p_body);
		_push_cameras_to_body(p_body);
	}
}

void Pasture3DPoolManager::unregister_body(Node *p_body) {
	_bodies.erase(p_body);
}

TypedArray<Node> Pasture3DPoolManager::get_bodies() const {
	TypedArray<Node> out;
	for (Node *body : _bodies) {
		if (body) {
			out.push_back(body);
		}
	}
	return out;
}

/**
 * The body a world point is inside, or null.
 *
 * Two passes on purpose. An ocean is unbounded, so a single pass in registration
 * order would return the ocean for a point plainly inside a pond whenever the ocean
 * happened to register first -- and registration order is scene-tree order, which no
 * user thinks about. Finite bodies are therefore asked first, and only if none claims
 * the point does the ocean get it.
 *
 * `contains_point` is duck-typed rather than an interface: Pasture3DPool is GDScript
 * and Pasture3DOcean is C++, and requiring a shared base would mean making one of
 * them the other's language.
 */
Node *Pasture3DPoolManager::body_at(const Vector3 &p_global_pos) const {
	Node *ocean = nullptr;
	for (Node *body : _bodies) {
		if (!body) {
			continue;
		}
		if (Object::cast_to<Pasture3DOcean>(body)) {
			if (!ocean) {
				ocean = body;
			}
			continue;
		}
		if (body->has_method("contains_point") &&
				(bool)body->call("contains_point", p_global_pos)) {
			return body;
		}
	}
	// The ocean is the fallback for every point no finite body claimed, INCLUDING one
	// above the surface -- so it is returned without being asked whether it contains the
	// point. It used to be asked, and the answer was discarded: both the guarded branch
	// and the fallthrough returned `ocean`, so a full Pasture3DOcean::contains_point() --
	// which compares against the WAVE surface and therefore runs solve_domain(), up to 16
	// iterations of the inverse -- was spent choosing between returning the ocean and returning
	// the ocean. On the buoy resolve path that ran per buoy per physics tick.
	//
	// Returning it unconditionally is also the behaviour a buoy wants: a hull lifted clear
	// of a crest must keep its body rather than drop to null and re-resolve on the next
	// tick. Submersion decides whether it gets force; this only decides whose surface to
	// measure against.
	return ocean;
}

real_t Pasture3DPoolManager::evaluate_height(const StringName &p_profile, const Vector2 &p_domain_xz) const {
	Ref<Pasture3DWaveProfile> profile = get_profile(p_profile);
	if (profile.is_null()) {
		return 0.f;
	}
	return profile->get_height_at(p_domain_xz, (real_t)_water_time);
}

Vector3 Pasture3DPoolManager::evaluate_normal(const StringName &p_profile, const Vector2 &p_domain_xz) const {
	Ref<Pasture3DWaveProfile> profile = get_profile(p_profile);
	if (profile.is_null()) {
		return Vector3(0.f, 1.f, 0.f);
	}
	return profile->get_normal_at(p_domain_xz, (real_t)_water_time);
}

Vector3 Pasture3DPoolManager::evaluate_surface_point(const StringName &p_profile, const Vector2 &p_domain_xz) const {
	Ref<Pasture3DWaveProfile> profile = get_profile(p_profile);
	if (profile.is_null()) {
		return Vector3(p_domain_xz.x, 0.f, p_domain_xz.y);
	}
	return profile->get_surface_point(p_domain_xz, (real_t)_water_time);
}

Vector2 Pasture3DPoolManager::solve_domain(const StringName &p_profile, const Vector2 &p_target_xz) const {
	Ref<Pasture3DWaveProfile> profile = get_profile(p_profile);
	if (profile.is_null()) {
		return p_target_xz;
	}
	// Counted AFTER the null check, so the number is solves actually run and not calls made.
	// A fixture whose profile does not resolve then reads zero, which is the honest answer:
	// nothing was solved, and a gate asserting on the count should fail rather than pass.
	_solve_count++;
	return profile->solve_domain(p_target_xz, (real_t)_water_time);
}

// The editor's configuration warning and the runtime log share one text (FFT spec §6.4 has the numbers).
const char *const Pasture3DPoolManager::FBM_CHOICE_WARNING =
		"wave_model is fBm on a renderer that can run the FFT. fBm is the compatibility model, for renderers "
		"without compute shaders (Compatibility, headless) and for exact, same-frame CPU height queries. Here "
		"it costs as much as the FFT and looks worse; to save GPU time lower fft_resolution instead. Fine for "
		"testing.";

PackedStringArray Pasture3DPoolManager::_get_configuration_warnings() const {
	PackedStringArray warnings;
	if (_managers.size() > 1) {
		warnings.push_back(
				"There is more than one Pasture3DPoolManager in the tree. water_time is a project-wide "
				"shader global, so they overwrite each other every frame and the clock runs at the "
				"rate of however many are present. Keep one.");
	}
	if (is_fbm_by_choice()) {
		warnings.push_back(FBM_CHOICE_WARNING);
	}
	if (_requested_wave_model() == WAVE_MODEL_FFT && Pasture3DWaterFFT::is_supported()) {
		const int asked = _requested_fft_resolution();
		const int runs = get_effective_fft_resolution();
		if (runs < asked) {
			warnings.push_back(vformat("fft_resolution asks for %d, but this GPU's compute limits (shared memory, "
									   "workgroup size) allow at most %d, so the FFT runs at %d.",
					asked, runs, runs));
		}
	}
	if (_sun_light.is_null()) {
		warnings.push_back(
				"No sun_light. Water is still lit by the scene, but its own sun-dependent terms "
				"(specular tint, scattering) sit at their defaults.");
	}
	// A duplicate profile name is silently first-wins in get_profile(), which is
	// the kind of thing that gets debugged for an hour. The scene's own only: one named
	// like a built-in is an override, on purpose.
	PackedStringArray names;
	for (int i = 0; i < _profiles.size(); i++) {
		Ref<Pasture3DWaveProfile> profile = _profiles[i];
		if (profile.is_valid()) {
			names.push_back(String(profile->get_profile_name()));
		}
	}
	for (int i = 0; i < names.size(); i++) {
		for (int j = i + 1; j < names.size(); j++) {
			if (names[i] == names[j]) {
				warnings.push_back("Two wave profiles are both named '" + names[i] +
						"'. Bodies select by name, so the second is unreachable.");
				i = names.size(); // one warning is enough
				break;
			}
		}
	}
	return warnings;
}

///////////////////////////
// Protected Functions
///////////////////////////

void Pasture3DPoolManager::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_ENTER_TREE: {
			LOG(INFO, "NOTIFICATION_ENTER_TREE");
			register_water_globals();
			register_water_settings();
			{
				Callable cb = callable_mp(this, &Pasture3DPoolManager::_on_project_settings_changed);
				ProjectSettings *ps = ProjectSettings::get_singleton();
				if (ps && !ps->is_connected("settings_changed", cb)) {
					ps->connect("settings_changed", cb);
				}
			}
			if (!_managers.has(this)) {
				_managers.push_back(this);
			}
			add_to_group(MANAGER_GROUP);
			add_to_group(Pasture3D::CAMERA_USER_GROUP);
			// A terrain that set its cameras before this manager entered the tree has already
			// broadcast, and a group broadcast reaches nobody who was not there to hear it. So the
			// manager asks once on the way in. This is the pull half of the push/pull pair, and it
			// is why no retry loop is needed on either side.
			_resolve_cameras();
			_connect_profiles();
			set_physics_process(true);
			set_process(true);
			update_configuration_warnings();
			break;
		}

		case NOTIFICATION_EXIT_TREE: {
			LOG(INFO, "NOTIFICATION_EXIT_TREE");
			_managers.erase(this);
			{
				Callable cb = callable_mp(this, &Pasture3DPoolManager::_on_project_settings_changed);
				ProjectSettings *ps = ProjectSettings::get_singleton();
				if (ps && ps->is_connected("settings_changed", cb)) {
					ps->disconnect("settings_changed", cb);
				}
			}
			remove_from_group(MANAGER_GROUP);
			remove_from_group(Pasture3D::CAMERA_USER_GROUP);
			set_physics_process(false);
			set_process(false);
			break;
		}

		case NOTIFICATION_PROCESS: {
			_tick_ffts(get_process_delta_time());
			break;
		}

		case NOTIFICATION_PHYSICS_PROCESS: {
			_update_clock(get_physics_process_delta_time());
			_update_sun();
			if (Engine::get_singleton()->is_editor_hint()) {
				_poll_base_materials();
			}
			break;
		}
	}
}

/**
 * Takes a camera list and the layer each camera reads, and hands it to every registered body.
 *
 * Called by Pasture3D's broadcast, and by hand in a scene with no terrain. Which of those a pair
 * came from decides precedence: see the members.
 */
void Pasture3DPoolManager::set_cameras(const TypedArray<Camera3D> &p_cameras,
		const PackedInt32Array &p_layers) {
	// A push from a terrain is distinguishable from a hand-set only by who is calling, and the
	// group broadcast is the only caller that is a terrain. Rather than sniff the caller, the
	// terrain's arrival is recorded the first time a broadcast lands -- and a broadcast is the only
	// thing that reaches this while a Pasture3D is in the tree.
	// Reaching here AT ALL is what marks the pair as the terrain's. The first version of this tried
	// to infer it by scanning the scene for a Pasture3D, which cannot work: with a terrain present a
	// hand-set call and a broadcast look identical, so the hand-set won and the precedence rule was
	// not implemented at all. Worse, the scan found a terrain in a DIFFERENT fixture and a manager
	// with no terrain of its own reported itself as terrain-driven. Who called is the only honest
	// signal, and splitting the two entry points is how to have it.
	_cameras_from_terrain = true;
	_view_cameras = p_cameras;
	_view_layers = p_layers;
	if (!_manual_cameras.is_empty()) {
		WARN_PRINT("Pasture3DPoolManager: cameras were set by hand with set_manual_cameras() and a "
				   "Pasture3D is also broadcasting them. The terrain wins -- clear the manual list "
				   "to silence this, or remove the terrain if the manual list is the intended one.");
	}
	update_configuration_warnings();
	_push_cameras_to_bodies();
}

/**
 * The camera list for a scene with NO Pasture3D in it, which water spec W4 requires to work.
 *
 * Loses to a terrain: if one has ever broadcast, this is stored and ignored, and warns rather than
 * silently doing nothing. Precedence is structural -- which method was called -- and not
 * last-writer, so the outcome does not depend on the order two systems happen to initialise in.
 */
void Pasture3DPoolManager::set_manual_cameras(const TypedArray<Camera3D> &p_cameras,
		const PackedInt32Array &p_layers) {
	_manual_cameras = p_cameras;
	_manual_layers = p_layers;
	if (_cameras_from_terrain) {
		WARN_PRINT("Pasture3DPoolManager: a Pasture3D is broadcasting the camera list, so this one "
				   "is being kept but not used. The terrain wins, so that terrain and water cannot "
				   "geomorph to different cameras and open a seam at every shoreline.");
		update_configuration_warnings();
		return;
	}
	_view_cameras = p_cameras;
	_view_layers = p_layers;
	update_configuration_warnings();
	_push_cameras_to_bodies();
}

/**
 * The terrain this manager belongs to, or null.
 *
 * An ANCESTOR first. A manager parented under a Pasture3D -- which is how the demo scene authors it
 * -- is saying which terrain it belongs to, and that is the only unambiguous answer in a scene with
 * more than one. The group scan is the fallback for a manager sitting beside the terrain, and it
 * takes the first, which is the same compromise water bodies make when resolving their manager.
 */
Pasture3D *Pasture3DPoolManager::_find_terrain() const {
	for (Node *n = get_parent(); n; n = n->get_parent()) {
		Pasture3D *terrain = Object::cast_to<Pasture3D>(n);
		if (terrain) {
			return terrain;
		}
	}
	if (!is_inside_tree()) {
		return nullptr;
	}
	TypedArray<Node> found = get_tree()->get_nodes_in_group(Pasture3D::TERRAIN_GROUP);
	for (int i = 0; i < found.size(); i++) {
		Pasture3D *terrain = Object::cast_to<Pasture3D>(found[i]);
		if (terrain) {
			return terrain;
		}
	}
	return nullptr;
}

/**
 * Asks the scene for a terrain's camera list, for a manager that entered after the broadcast.
 */
void Pasture3DPoolManager::_resolve_cameras() {
	Pasture3D *terrain = _find_terrain();
	if (!terrain) {
		return;
	}
	_cameras_from_terrain = true;
	_view_cameras = terrain->get_cameras();
	_view_layers.clear();
	// Mirrors _broadcast_cameras(): 0 or 1 cameras is the single-view path and sends nothing, so a
	// manager pulling must arrive at the same empty pair rather than a list of one.
	if (_view_cameras.size() > 1) {
		for (int i = 0; i < _view_cameras.size(); i++) {
			const int bit = Pasture3D::TERRAIN_TOP_BIT - i;
			_view_layers.push_back(bit >= 0 ? (int32_t)(1u << uint32_t(bit)) : 1);
		}
	} else {
		_view_cameras.clear();
	}
	_push_cameras_to_bodies();
}

/**
 * Hands the pair to every registered body that can take it.
 *
 * Duck-typed for the same reason the group is: a body is GDScript (Pasture3DPool) or C++
 * (Pasture3DOcean), and only one of those can implement an interface.
 */
void Pasture3DPoolManager::_push_cameras_to_bodies() {
	for (int i = 0; i < _bodies.size(); i++) {
		Node *body = _bodies[i];
		if (body && body->has_method("set_view_cameras")) {
			body->call("set_view_cameras", _view_cameras, _view_layers);
		}
	}
}

void Pasture3DPoolManager::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_profiles", "profiles"), &Pasture3DPoolManager::set_profiles);
	ClassDB::bind_method(D_METHOD("get_profiles"), &Pasture3DPoolManager::get_profiles);
	ClassDB::bind_method(D_METHOD("get_builtin_profiles"), &Pasture3DPoolManager::get_builtin_profiles);
	ClassDB::bind_method(D_METHOD("get_builtin_profile_names"), &Pasture3DPoolManager::get_builtin_profile_names);
	ClassDB::bind_method(D_METHOD("is_builtin_profile_name", "name"), &Pasture3DPoolManager::is_builtin_profile_name);
	ClassDB::bind_method(D_METHOD("override_builtin", "name"), &Pasture3DPoolManager::override_builtin);
	ClassDB::bind_static_method("Pasture3DPoolManager", D_METHOD("profiles_store_same_knobs", "a", "b", "skip_fft"),
			&Pasture3DPoolManager::profiles_store_same_knobs, DEFVAL(PackedStringArray()));
	ClassDB::bind_method(D_METHOD("set_loop_period", "seconds"), &Pasture3DPoolManager::set_loop_period);
	ClassDB::bind_method(D_METHOD("get_loop_period"), &Pasture3DPoolManager::get_loop_period);
	ClassDB::bind_method(D_METHOD("set_sun_light", "light"), &Pasture3DPoolManager::set_sun_light);
	ClassDB::bind_method(D_METHOD("get_sun_light"), &Pasture3DPoolManager::get_sun_light);
	BIND_ENUM_CONSTANT(WAVE_MODEL_FFT);
	BIND_ENUM_CONSTANT(WAVE_MODEL_FBM);
	BIND_ENUM_CONSTANT(WAVE_MODEL_PROJECT);
	ClassDB::bind_method(D_METHOD("set_wave_model", "model"), &Pasture3DPoolManager::set_wave_model);
	ClassDB::bind_method(D_METHOD("get_wave_model"), &Pasture3DPoolManager::get_wave_model);
	ClassDB::bind_method(D_METHOD("is_fft_effective"), &Pasture3DPoolManager::is_fft_effective);
	ClassDB::bind_method(D_METHOD("get_effective_wave_model"), &Pasture3DPoolManager::get_effective_wave_model);
	ClassDB::bind_method(D_METHOD("is_wave_model_fallback"), &Pasture3DPoolManager::is_wave_model_fallback);
	ClassDB::bind_method(D_METHOD("is_fbm_by_choice"), &Pasture3DPoolManager::is_fbm_by_choice);
	ClassDB::bind_method(D_METHOD("get_manager_warnings"), &Pasture3DPoolManager::get_manager_warnings);
	ClassDB::bind_method(D_METHOD("get_effective_fft_resolution"), &Pasture3DPoolManager::get_effective_fft_resolution);
	ClassDB::bind_method(D_METHOD("refresh_project_settings"), &Pasture3DPoolManager::refresh_project_settings);
	ClassDB::bind_static_method("Pasture3DPoolManager", D_METHOD("register_water_settings"),
			&Pasture3DPoolManager::register_water_settings);
	ClassDB::bind_method(D_METHOD("set_fft_resolution", "resolution"), &Pasture3DPoolManager::set_fft_resolution);
	ClassDB::bind_method(D_METHOD("get_fft_resolution"), &Pasture3DPoolManager::get_fft_resolution);
	ClassDB::bind_method(D_METHOD("get_live_fft_count"), &Pasture3DPoolManager::get_live_fft_count);
	ClassDB::bind_method(D_METHOD("get_fft_tick_count"), &Pasture3DPoolManager::get_fft_tick_count);
	ClassDB::bind_method(D_METHOD("get_fft_rebind_count"), &Pasture3DPoolManager::get_fft_rebind_count);
	ClassDB::bind_method(D_METHOD("set_paused", "paused"), &Pasture3DPoolManager::set_paused);
	ClassDB::bind_method(D_METHOD("is_paused"), &Pasture3DPoolManager::is_paused);

	ClassDB::bind_method(D_METHOD("get_water_time"), &Pasture3DPoolManager::get_water_time);
	ClassDB::bind_method(D_METHOD("get_profile", "name"), &Pasture3DPoolManager::get_profile);
	ClassDB::bind_method(D_METHOD("get_profile_names"), &Pasture3DPoolManager::get_profile_names);
	ClassDB::bind_method(D_METHOD("has_profile", "name"), &Pasture3DPoolManager::has_profile);

	ClassDB::bind_method(D_METHOD("get_material_for", "base", "profile"), &Pasture3DPoolManager::get_material_for);
	ClassDB::bind_method(D_METHOD("get_cached_material_count"), &Pasture3DPoolManager::get_cached_material_count);
	ClassDB::bind_method(D_METHOD("get_upload_count"), &Pasture3DPoolManager::get_upload_count);
	ClassDB::bind_method(D_METHOD("get_solve_count"), &Pasture3DPoolManager::get_solve_count);
	ClassDB::bind_method(D_METHOD("reset_solve_count"), &Pasture3DPoolManager::reset_solve_count);
	ClassDB::bind_method(D_METHOD("clear_material_cache"), &Pasture3DPoolManager::clear_material_cache);
	ClassDB::bind_method(D_METHOD("rebuild_tables"), &Pasture3DPoolManager::rebuild_tables);
	ClassDB::bind_method(D_METHOD("upload_profile_into", "material", "profile"), &Pasture3DPoolManager::upload_profile_into);
	// Bound for the same reason upload_profile_into is: the bodies that need it are
	// outside this class's cache. It is also the only way a gate can drive the sync,
	// since the callers run it behind is_editor_hint() and a headless test is not the
	// editor.
	ClassDB::bind_static_method("Pasture3DPoolManager",
			D_METHOD("sync_material_params", "base", "target"), &Pasture3DPoolManager::sync_material_params);
	ClassDB::bind_static_method("Pasture3DPoolManager",
			D_METHOD("is_plugin_written_param", "name"), &Pasture3DPoolManager::is_plugin_written_param);
	ClassDB::bind_method(D_METHOD("set_cameras", "cameras", "layers"), &Pasture3DPoolManager::set_cameras);
	ClassDB::bind_method(D_METHOD("set_manual_cameras", "cameras", "layers"), &Pasture3DPoolManager::set_manual_cameras);
	ClassDB::bind_method(D_METHOD("get_view_cameras"), &Pasture3DPoolManager::get_view_cameras);
	ClassDB::bind_method(D_METHOD("get_view_layers"), &Pasture3DPoolManager::get_view_layers);
	ClassDB::bind_method(D_METHOD("are_cameras_from_terrain"), &Pasture3DPoolManager::are_cameras_from_terrain);
	ClassDB::bind_method(D_METHOD("register_body", "body"), &Pasture3DPoolManager::register_body);
	ClassDB::bind_method(D_METHOD("unregister_body", "body"), &Pasture3DPoolManager::unregister_body);
	ClassDB::bind_method(D_METHOD("get_bodies"), &Pasture3DPoolManager::get_bodies);
	ClassDB::bind_method(D_METHOD("body_at", "global_pos"), &Pasture3DPoolManager::body_at);

	ADD_SIGNAL(MethodInfo("profiles_changed"));
	// A wave simulation built new output textures. Anything holding a PRIVATE copy of a water material
	// re-uploads its profile into it; see Pasture3DWaterFFT::get_texture_generation().
	ADD_SIGNAL(MethodInfo("wave_textures_changed"));

	ClassDB::bind_method(D_METHOD("evaluate_height", "profile", "domain_xz"), &Pasture3DPoolManager::evaluate_height);
	ClassDB::bind_method(D_METHOD("evaluate_normal", "profile", "domain_xz"), &Pasture3DPoolManager::evaluate_normal);
	ClassDB::bind_method(D_METHOD("evaluate_surface_point", "profile", "domain_xz"), &Pasture3DPoolManager::evaluate_surface_point);
	ClassDB::bind_method(D_METHOD("solve_domain", "profile", "target_xz"), &Pasture3DPoolManager::solve_domain);

	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "profiles", PROPERTY_HINT_TYPE_STRING,
						 String::num(Variant::OBJECT) + "/" + String::num(PROPERTY_HINT_RESOURCE_TYPE) + ":Pasture3DWaveProfile"),
			"set_profiles", "get_profiles");
	// Shown so the scene's author can see what the names select; read-only and never saved.
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "builtin_profiles", PROPERTY_HINT_TYPE_STRING,
						 String::num(Variant::OBJECT) + "/" + String::num(PROPERTY_HINT_RESOURCE_TYPE) + ":Pasture3DWaveProfile",
						 PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY),
			"", "get_builtin_profiles");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "loop_period", PROPERTY_HINT_RANGE, "1,600,0.5,or_greater,suffix:s"),
			"set_loop_period", "get_loop_period");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "sun_light", PROPERTY_HINT_NODE_TYPE, "DirectionalLight3D"),
			"set_sun_light", "get_sun_light");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "paused"), "set_paused", "is_paused");
	ADD_GROUP("Waves", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "wave_model", PROPERTY_HINT_ENUM, "FFT:0,fBm:2,Project Setting:3"), "set_wave_model", "get_wave_model");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "fft_resolution", PROPERTY_HINT_ENUM, "Project Setting:0,128:128,256:256,512:512,1024:1024"),
			"set_fft_resolution", "get_fft_resolution");
}
