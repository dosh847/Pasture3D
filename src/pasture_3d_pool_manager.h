// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
// The scene's water authority: wave profiles, the clock, the sun, the material cache.
// Spec: PASTURE3D_WATER_BODIES_SPEC.md §5

#ifndef PASTURE3D_POOL_MANAGER_CLASS_H
#define PASTURE3D_POOL_MANAGER_CLASS_H

#include <godot_cpp/classes/directional_light3d.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include "constants.h"
#include "pasture_3d_wave_profile.h"
#include "target_node_3d.h"

using namespace godot;

/**
 * One node per scene owns everything every water body shares.
 *
 * Before this existed the ocean owned all of it, and a lake had no way to reach any
 * of it: the wave table was uploaded into the ocean's material by Pasture3D, and a
 * MeshInstance3D with a lake material got whatever compile-time default its variant
 * happened to carry. That is why the water guide's advice for a pond is "edit 32
 * floats, or run a script" -- there was nothing to ask.
 *
 * Four responsibilities, and they are together because they are the same
 * information seen four ways:
 *
 *   1. PROFILES. Named sets of wave knobs. Bodies select one by name.
 *   2. THE CLOCK. water_time / water_time_period, written once per physics frame.
 *      Project-wide shader globals, so one write drives every body in the scene.
 *   3. THE SUN. water_sun_direction / water_sun_color, from a DirectionalLight3D.
 *   4. THE MATERIAL CACHE. One material per distinct (base material, profile) pair,
 *      with the profile's table uploaded into it once. Ten ponds on one profile cost
 *      one material and one upload -- which is only possible because
 *      _water_domain_origin became an instance uniform (§5.4).
 *
 * Coexistence with Pasture3D's ocean, for the life of Phase 1: Pasture3D still owns
 * an ocean and still wants to drive the clock. Two writers of one global is one
 * writer too many, so Pasture3D yields whenever a manager is in the tree -- see
 * has_active_manager(). Phase 2 deletes the losing side.
 */
class Pasture3D;

class Pasture3DPoolManager : public Node3D {
	GDCLASS(Pasture3DPoolManager, Node3D);
	CLASS_NAME();

public: // Constants
	// Which wave model the materials draw (PASTURE3D_WATER_FFT_SPEC.md §4). PROJECT, the default, reads
	// SETTING_WAVE_MODEL, so a game's options menu can switch every scene without a node reference. FFT
	// falls back to fBm where there is no RenderingDevice (Compatibility, headless), and says so once.
	// 1 was GERSTNER, retired in Phase 6; the others keep their values so saved scenes keep their meaning.
	enum WaveModel {
		WAVE_MODEL_FFT = 0,
		WAVE_MODEL_FBM = 2,
		WAVE_MODEL_PROJECT = 3,
	};
	// The values the shader's `_wave_model` uniform takes, from water_common.gdshaderinc. Spelled out
	// rather than reusing the enum, whose values are the saved scenes' and not the shader's.
	static constexpr int SHADER_MODEL_FFT = Pasture3DWaveProfile::MODEL_FFT;
	static constexpr int SHADER_MODEL_FBM = Pasture3DWaveProfile::MODEL_FBM;

	// Project settings behind WAVE_MODEL_PROJECT and fft_resolution 0. wave_model is 0 = FFT, 1 = fBm.
	static constexpr const char *SETTING_WAVE_MODEL = "pasture_3d/water/wave_model";
	static constexpr const char *SETTING_FFT_RESOLUTION = "pasture_3d/water/fft_resolution";

	// Bodies find their manager by group. Matches WATER_MANAGER_GROUP in the spec.
	//
	// A `const char *` and not a `static inline StringName`. A StringName built at
	// static-initialisation time runs before godot-cpp has brought up its string
	// interner, and the DLL then fails to load at all -- Windows reports it as
	// "Error 1114: a dynamic link library initialization routine failed", with no
	// indication of which line. add_to_group() takes a StringName and converts.
	static constexpr const char *MANAGER_GROUP = "pasture3d_water_manager";

private:
	// Process-global count of managers currently in a tree. Pasture3D reads it to
	// decide whether to drive the clock, and the answer has to be about the whole
	// process rather than about one scene: the RenderingServer global table is
	// process-wide, so a manager in ANY open scene is a second writer.
	// Every manager currently in a tree, in the order they entered. A LIST and not a
	// single pointer: managers overlap. A queue_free()d manager stays in the tree
	// until the frame ends, so a replacement entering before it leaves would decline
	// to take over (the slot looked occupied) and then be orphaned when the outgoing
	// one cleared the slot -- leaving no active manager while one was plainly in the
	// scene. Scene switching does exactly that, and the Phase 1 gate caught it.
	static inline Vector<Pasture3DPoolManager *> _managers;

	// Water bodies registered with this manager, in registration order. Deferred
	// from Phase 1 because nothing implemented a body yet and a registry that
	// cannot be gated is a registry that only compiles.
	Vector<Node *> _bodies;

	// SPLIT-SCREEN CAMERAS, and which render layer each one reads.
	//
	// Two sources and a stated precedence, because water spec W4 requires water to work in a scene
	// with no Pasture3D in it -- so the terrain cannot be the only way in -- while a scene that HAS
	// one must not end up with terrain and water geomorphing to different centres, which would show
	// as a seam at every shoreline.
	//
	// The terrain's pair wins whenever a terrain has ever broadcast, and _cameras_from_terrain is
	// what records that rather than a non-empty list: an empty list is a legitimate terrain state
	// (solo play), and treating it as "no terrain" would silently hand control back to a stale
	// hand-set list.
	TypedArray<Camera3D> _view_cameras;
	PackedInt32Array _view_layers;
	TypedArray<Camera3D> _manual_cameras;
	PackedInt32Array _manual_layers;
	bool _cameras_from_terrain = false;

	void _push_cameras_to_bodies();
	void _push_cameras_to_body(Node *p_body);
	void _resolve_cameras();
	Pasture3D *_find_terrain() const;
	// The first manager to enter a tree, and the one Pasture3D adopts its clock
	// from. A raw pointer is safe only because EXIT_TREE clears it; nothing else
	// may hold it across a frame.

	TypedArray<Pasture3DWaveProfile> _profiles;
	real_t _loop_period = 120.f;
	WaveModel _wave_model = WAVE_MODEL_PROJECT;
	// 0 = the project setting.
	int _fft_resolution = 0;
	// What _apply_model_to_profiles() last applied, so a project-settings change that moves neither costs
	// nothing: settings_changed fires for every setting in the project.
	int _applied_model = -1;
	int _applied_resolution = -1;
	// The no-device warning is about the machine, not the scene: once per process.
	static inline bool _fallback_warned = false;
	// Likewise the fBm-by-choice warning: once per process, whichever manager asks first.
	static inline bool _choice_warned = false;
	static const char *const FBM_CHOICE_WARNING;
	// Simulations some material samples, in first-upload order. Only these are ticked: a profile no body
	// selects costs nothing. Unique by pointer, so a simulation two profiles share is ticked once.
	Vector<Ref<Pasture3DWaterFFT>> _live_ffts;
	// Each live simulation's texture generation as of the last upload, parallel to _live_ffts.
	Vector<int> _live_fft_generations;
	int _rebind_count = 0;
	int _fft_tick_count = 0;
	TargetNode3D _sun_light;
	bool _paused = false;

	double _water_time = 0.0;
	// Last value pushed to water_time_period; -1 forces the first write.
	float _period_sent = -1.f;
	// Last sun values pushed, so a static sun costs no RenderingServer traffic.
	Vector3 _sun_dir_sent = V3_MAX;
	Vector3 _sun_color_sent = V3_MAX;

	// One cached duplicate, with the base it was taken from.
	//
	// The base is kept rather than reachable only through the key's instance id, because
	// a duplicate is a SNAPSHOT: tuning the preset in the inspector moves the base and
	// leaves every body still drawing the copy taken at load. Resource's `changed`
	// carries no argument naming which resource moved, so the base has to be here to be
	// copied from. `profile` likewise, instead of being parsed back out of the key.
	struct CachedMaterial {
		Ref<Material> base;
		Ref<Material> shared;
		StringName profile;
	};
	// (base material instance id, profile name) -> the shared duplicate handed out.
	HashMap<String, CachedMaterial> _material_cache;
	// Cumulative count of profile uploads. The Phase 1 gate asserts ten pools on one
	// profile produce exactly one; it is kept afterwards because "how many uploads
	// did that inspector drag cost" is the question this class exists to answer.
	int _upload_count = 0;
	// Cumulative count of solve_domain() solves. The same instrument as _upload_count, for
	// the other expensive thing this class does.
	//
	// An FFT inverse is up to 16 iterations over the readback and it is the entire cost
	// of every CPU water query -- so "how many did that tick cost" is the only question worth
	// asking about buoy performance, and it is an INTEGER. The buoy budget used to be stated
	// in milliseconds and verified on whatever machine was free, which is how a doubling on
	// the ocean path survived a green gate. A count is reproducible on a contended machine
	// and says which of two implementations was measured.
	//
	// mutable because solve_domain() is const and must stay const.
	mutable int _solve_count = 0;

	String _cache_key(const Ref<Material> &p_base, const StringName &p_profile) const;
	void _upload_into(const Ref<Material> &p_material, const Ref<Pasture3DWaveProfile> &p_profile);
	void _poll_base_materials();
	void _on_profile_changed();
	void _connect_profiles();
	void _seed_default_profiles();
	void _update_clock(const double p_delta);
	void _update_sun();
	void _apply_model_to_profiles();
	void _reupload_cache();
	void _tick_ffts(const double p_delta);
	void _on_project_settings_changed();
	// The requested model with PROJECT resolved, before the no-device fallback.
	WaveModel _requested_wave_model() const;

protected:
	static void _bind_methods();
	void _notification(int p_what);

public:
	Pasture3DPoolManager();
	~Pasture3DPoolManager();

	// True when any Pasture3DPoolManager is in a tree. Pasture3D consults this before
	// writing the clock globals; see the class comment.
	static bool has_active_manager() { return !_managers.is_empty(); }
	// The manager driving the clock, or null. Pasture3D reads its water_time so the
	// ocean's CPU query stays on the same instant as the drawn surface.
	static Pasture3DPoolManager *get_active_manager() {
		return _managers.is_empty() ? nullptr : _managers[0];
	}
	static int get_active_manager_count() { return _managers.size(); }

	// Declares water_time / water_time_period / water_sun_* on the RenderingServer
	// if the project settings did not already. Process-global and idempotent.
	//
	// Static, and called by Pasture3DOcean as well as by this node, because an ocean or a
	// bare MeshInstance3D with a water material can exist in a scene with no
	// manager at all -- and a water material loaded before these exist makes Godot
	// warn that a global "was removed at some point" and render it black until it
	// recompiles. Moved here from Pasture3D in Phase 2.
	static void register_water_globals();
	// Declares SETTING_WAVE_MODEL and SETTING_FFT_RESOLUTION with their hints, if absent. Idempotent.
	static void register_water_settings();

	// Copies p_base's ART parameters into p_target, leaving p_target's RID alone.
	// Returns true if anything was written.
	//
	// Why this exists: every water body draws with a DUPLICATE of its base material
	// (this class's cache, or Pasture3DOcean's private copy), and a duplicate is a snapshot.
	// Tuning the base preset in the inspector moved the base and left every body drawing
	// the copy taken at load, with no indication the slider had done nothing.
	//
	// Why it is a copy and not a re-duplicate: Pasture3DMesher bakes the material RID into
	// its mesh surfaces (mesh_surface_set_material), so handing the ocean a NEW
	// duplicate means rebuilding the whole clipmap -- per keystroke, while a slider is
	// being dragged. Copying keeps the RID.
	//
	// Why callers POLL this rather than connect to something: ShaderMaterial emits no
	// signal when a parameter changes. Not `changed`, not `property_list_changed`,
	// through set_shader_parameter() or through set("shader_parameter/..") -- checked,
	// because the obvious fix is a `changed` connection that would silently never fire.
	// A directly-assigned material needs no signal (the RID is the same object); only a
	// duplicate does, and nothing in the engine announces it. So this compares before it
	// writes, and a poll over an untouched material costs reads and no RenderingServer
	// traffic.
	//
	// PLUGIN-WRITTEN UNIFORMS ARE SKIPPED -- `_`-prefixed ones (`_wave_model`, `_fft_*`,
	// `_fbm_*`, `_mesh_size`, `_subdiv`, `_vertex_spacing`, `_target_pos`), plus `sea_level`.
	// They are owned by the profile, the ocean or the clipmap, and a base that does not
	// store them yields nil; copying that would erase the model every frame and the poll
	// would fight whoever re-applied it.
	static bool sync_material_params(const Ref<Material> &p_base, const Ref<Material> &p_target);
	// True for a uniform the plugin writes and the base material does not own.
	static bool is_plugin_written_param(const StringName &p_name);

	void set_profiles(const TypedArray<Pasture3DWaveProfile> &p_profiles);
	TypedArray<Pasture3DWaveProfile> get_profiles() const { return _profiles; }
	void set_loop_period(const real_t p_seconds);
	real_t get_loop_period() const { return _loop_period; }
	void set_sun_light(Node3D *p_light);
	Node3D *get_sun_light() const { return _sun_light.ptr(); }
	void set_wave_model(const WaveModel p_model);
	WaveModel get_wave_model() const { return _wave_model; }
	// What the materials actually draw: FFT or FBM. PROJECT resolved, and FFT -> FBM where the
	// renderer has no RenderingDevice.
	WaveModel get_effective_wave_model() const;
	bool is_fft_effective() const { return get_effective_wave_model() == WAVE_MODEL_FFT; }
	// True when the FFT was asked for and the fBm is drawn instead because there is no device.
	bool is_wave_model_fallback() const;
	// fBm was ASKED for (here or through the project setting) on a renderer that can run the FFT. fBm is the
	// compatibility model: on Forward+/Mobile it costs as much as the FFT and looks worse (FFT spec §6.4),
	// so this warns. Still selectable, for testing and for exact CPU height queries.
	bool is_fbm_by_choice() const;
	void set_fft_resolution(const int p_resolution);
	int get_fft_resolution() const { return _fft_resolution; }
	// The resolution the simulations run at: the property, or the project setting when it is 0.
	int get_effective_fft_resolution() const;
	// Re-reads the project settings and re-applies the model if the answer moved. Connected to
	// ProjectSettings.settings_changed; bound so a game that writes the settings can apply them at once.
	void refresh_project_settings() { _on_project_settings_changed(); }
	int get_live_fft_count() const { return _live_ffts.size(); }
	// Simulation dispatches since this manager was made. A gate's witness that the tick runs.
	int get_fft_tick_count() const { return _fft_tick_count; }
	// Re-uploads caused by a simulation building new textures. A gate's witness for the rebind.
	int get_fft_rebind_count() const { return _rebind_count; }
	void set_paused(const bool p_paused);
	bool is_paused() const { return _paused; }

	// The wrapped clock both the CPU queries and the shaders run on. Not
	// Time.get_ticks_msec(), and not Godot's TIME.
	real_t get_water_time() const { return (real_t)_water_time; }

	Ref<Pasture3DWaveProfile> get_profile(const StringName &p_name) const;
	PackedStringArray get_profile_names() const;
	bool has_profile(const StringName &p_name) const { return get_profile(p_name).is_valid(); }

	// The shared duplicate for this (base, profile) pair, built and uploaded on
	// first ask. Returns the base itself if the profile does not resolve, so a
	// mistyped name renders water rather than nothing.
	Ref<Material> get_material_for(const Ref<Material> &p_base, const StringName &p_profile);
	// Writes a profile's table into a material the caller owns. For bodies that
	// cannot use the shared cache because they write their own uniforms into their
	// material -- Pasture3DOcean and its clipmap parameters are the case this exists for.
	void upload_profile_into(const Ref<Material> &p_material, const StringName &p_profile);
	int get_cached_material_count() const { return _material_cache.size(); }
	int get_upload_count() const { return _upload_count; }
	// Solves run since the last reset. See _solve_count.
	int get_solve_count() const { return _solve_count; }
	void reset_solve_count() { _solve_count = 0; }
	void clear_material_cache();

	// Rebuilds every profile's table and re-uploads it into every cached material.
	void rebuild_tables();

	// --- Body registry (spec §5.5) ------------------------------------------
	// Bodies register on entering the tree. The contract a body must satisfy is one
	// duck-typed method, `contains_point(global_pos) -> bool`, so a GDScript
	// Pasture3DPool and a C++ Pasture3DOcean can both be bodies without a shared
	// base class.
	// CAMERA_USER_GROUP's one method, called by Pasture3D on every camera change. Calling it counts
	// as being the terrain -- see the .cpp -- so a scene with no Pasture3D wants set_manual_cameras().
	void set_cameras(const TypedArray<Camera3D> &p_cameras, const PackedInt32Array &p_layers);
	void set_manual_cameras(const TypedArray<Camera3D> &p_cameras, const PackedInt32Array &p_layers);
	TypedArray<Camera3D> get_view_cameras() const { return _view_cameras; }
	PackedInt32Array get_view_layers() const { return _view_layers; }
	// Whether the pair above came from a terrain. Read by the configuration warnings, and by a bench
	// that needs to tell "the terrain pushed" from "nothing did".
	bool are_cameras_from_terrain() const { return _cameras_from_terrain; }

	void register_body(Node *p_body);
	void unregister_body(Node *p_body);
	TypedArray<Node> get_bodies() const;
	// The innermost body containing a world point, or null. Finite bodies are asked
	// first and the ocean is the fallback -- an ocean is infinite, so asking it first
	// would mean no pool was ever found.
	Node *body_at(const Vector3 &p_global_pos) const;

	// --- Evaluation, in DOMAIN space (spec §5.5) ----------------------------
	// World-space queries belong to the bodies, which apply their own surface
	// height and domain origin. These are the primitives underneath, taken at the
	// current water_time unless one is given.
	real_t evaluate_height(const StringName &p_profile, const Vector2 &p_domain_xz) const;
	Vector3 evaluate_normal(const StringName &p_profile, const Vector2 &p_domain_xz) const;
	Vector3 evaluate_surface_point(const StringName &p_profile, const Vector2 &p_domain_xz) const;
	// Inverse: the domain parameter whose displaced point lands on p_target_xz.
	Vector2 solve_domain(const StringName &p_profile, const Vector2 &p_target_xz) const;

	// The same text _get_configuration_warnings() shows, as a BOUND method, for the reason
	// Pasture3DOcean::get_ocean_warnings() exists: GDExtension virtuals are not callable from script,
	// so a bench could not otherwise assert the fBm-by-choice warning is shown.
	PackedStringArray get_manager_warnings() const { return _get_configuration_warnings(); }

	PackedStringArray _get_configuration_warnings() const;
};

VARIANT_ENUM_CAST(Pasture3DPoolManager::WaveModel);

#endif // PASTURE3D_POOL_MANAGER_CLASS_H
