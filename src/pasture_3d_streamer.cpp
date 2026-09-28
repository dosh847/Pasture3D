// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <algorithm>

#include "logger.h"
#include "pasture_3d.h"
#include "pasture_3d_data.h"
#include "pasture_3d_layer_stack.h"
#include "pasture_3d_region_index.h"
#include "pasture_3d_region_type.h"
#include "pasture_3d_streamer.h"
#include "pasture_3d_util.h"

///////////////////////////
// Private Functions
///////////////////////////

Pasture3D *Pasture3DStreamer::_get_terrain() const {
	if (Pasture3D *terrain = Object::cast_to<Pasture3D>(_terrain.get_target())) {
		return terrain;
	}
	return Object::cast_to<Pasture3D>(get_parent());
}

// The sources set, or with none set, the terrain's cameras, or the viewport's camera.
std::vector<Node3D *> Pasture3DStreamer::_resolve_sources() const {
	std::vector<Node3D *> nodes;
	for (const TargetNode3D &source : _sources) {
		if (source.is_valid()) {
			nodes.push_back(source.get_target());
		}
	}
	if (!nodes.empty() || !_sources.empty()) {
		return nodes; // Sources were set: never fall back because they all left the tree
	}
	if (const Pasture3D *terrain = _get_terrain()) {
		const TypedArray<Camera3D> cams = terrain->get_cameras();
		for (int i = 0; i < cams.size(); i++) {
			Camera3D *cam = Object::cast_to<Camera3D>(cams[i]);
			if (cam && cam->is_inside_tree()) {
				nodes.push_back(cam);
			}
		}
	}
	if (nodes.empty() && is_inside_tree() && get_viewport()) {
		if (Camera3D *cam = get_viewport()->get_camera_3d()) {
			nodes.push_back(cam);
		}
	}
	return nodes;
}

// A loaded region answers for itself; an unloaded one by its index entry. Either way "" is Standard.
Ref<Pasture3DRegionType> Pasture3DStreamer::_type_of(const Vector2i &p_loc) const {
	const Pasture3D *terrain = _get_terrain();
	const Pasture3DData *data = terrain->get_data();
	if (const Pasture3DRegion *region = data->get_region_ptr(p_loc)) {
		return data->get_region_type_of(region);
	}
	const String path = data->get_region_index()->get_entry(p_loc).get("type_path", String());
	if (!_type_cache.has(path)) {
		const_cast<Pasture3DStreamer *>(this)->_type_cache[path] = data->load_region_type(path);
	}
	return _type_cache[path];
}

// From the nearest source to the region's footprint, in the XZ plane. 0 inside it.
real_t Pasture3DStreamer::_distance_to(const Vector2i &p_loc, const PackedVector3Array &p_positions, const real_t p_region_world) const {
	real_t best = FLT_MAX;
	const Vector2 lo = Vector2(p_loc) * p_region_world;
	const Vector2 hi = lo + Vector2(p_region_world, p_region_world);
	for (int i = 0; i < p_positions.size(); i++) {
		const Vector2 p = Vector2(p_positions[i].x, p_positions[i].z);
		const Vector2 d = Vector2(MAX(MAX(lo.x - p.x, p.x - hi.x), real_t(0.f)), MAX(MAX(lo.y - p.y, p.y - hi.y), real_t(0.f)));
		best = MIN(best, d.length());
	}
	return best;
}

void Pasture3DStreamer::_feed(Pasture3D *p_terrain, const std::vector<Node3D *> &p_sources) {
	std::vector<uint64_t> ids;
	for (Node3D *node : p_sources) {
		ids.push_back(node->get_instance_id());
	}
	if (ids == _fed_ids) {
		return;
	}
	_fed_ids = ids;
	TypedArray<Node3D> nodes;
	for (Node3D *node : p_sources) {
		nodes.push_back(node);
	}
	p_terrain->set_collision_targets(nodes);
}

// Begins reading a region: on a worker thread, or (threaded off) right here.
bool Pasture3DStreamer::_start(Pasture3D *p_terrain, const Vector2i &p_loc) {
	const String dir = p_terrain->get_data_directory();
	Pending pending;
	pending.path = Pasture3DData::region_file_path(dir, p_loc, &pending.legacy);
	if (pending.path.is_empty()) {
		LOG(ERROR, "Region ", p_loc, " is in the index but has no file in ", dir);
		_failed.insert(p_loc);
		return false;
	}
	const String slice_path = dir + String("/") + Util::location_to_layer_filename(p_loc);
	if (FileAccess::file_exists(slice_path)) {
		pending.slice_path = slice_path;
	}
	ResourceLoader *loader = ResourceLoader::get_singleton();
	_requests++;
	if (_threaded) {
		if (loader->load_threaded_request(pending.path, "Pasture3DRegion", false, ResourceLoader::CACHE_MODE_IGNORE) != OK ||
				(!pending.slice_path.is_empty() &&
						loader->load_threaded_request(pending.slice_path, "Pasture3DLayerStack", false, ResourceLoader::CACHE_MODE_IGNORE) != OK)) {
			LOG(ERROR, "Cannot start reading region ", p_loc, " from ", pending.path);
			_failed.insert(p_loc);
			return false;
		}
		pending.threaded = true;
		_threaded_requests++;
	} else {
		pending.region = loader->load(pending.path, "Pasture3DRegion", ResourceLoader::CACHE_MODE_IGNORE);
		if (!pending.slice_path.is_empty()) {
			pending.slice = loader->load(pending.slice_path, "Pasture3DLayerStack", ResourceLoader::CACHE_MODE_IGNORE);
		}
	}
	_pending[p_loc] = pending;
	return true;
}

// Collects every threaded read that has finished. A failed read is dropped and not retried.
void Pasture3DStreamer::_poll() {
	ResourceLoader *loader = ResourceLoader::get_singleton();
	for (auto &[loc, pending] : _pending) {
		if (!pending.threaded || pending.region.is_valid()) {
			continue;
		}
		const ResourceLoader::ThreadLoadStatus region_status = loader->load_threaded_get_status(pending.path);
		const ResourceLoader::ThreadLoadStatus slice_status = pending.slice_path.is_empty() ?
				ResourceLoader::THREAD_LOAD_LOADED :
				loader->load_threaded_get_status(pending.slice_path);
		if (region_status == ResourceLoader::THREAD_LOAD_IN_PROGRESS || slice_status == ResourceLoader::THREAD_LOAD_IN_PROGRESS) {
			continue;
		}
		// Both done (or failed): collect them, which also frees the loader's hold on them.
		pending.region = region_status == ResourceLoader::THREAD_LOAD_LOADED ? loader->load_threaded_get(pending.path) : Ref<Resource>();
		if (!pending.slice_path.is_empty() && slice_status == ResourceLoader::THREAD_LOAD_LOADED) {
			pending.slice = loader->load_threaded_get(pending.slice_path);
		}
		if (pending.region.is_null()) {
			LOG(ERROR, "Reading region ", loc, " from ", pending.path, " failed");
			_failed.insert(loc);
			pending.dropped = true;
		}
	}
}

///////////////////////////
// Public Functions
///////////////////////////

void Pasture3DStreamer::tick() {
	Pasture3D *terrain = _get_terrain();
	if (!_enabled || !terrain || !terrain->get_data() || !terrain->get_data()->get_region_index().is_valid()) {
		return;
	}
	Pasture3DData *data = terrain->get_data();
	_frames++;
	const std::vector<Node3D *> sources = _resolve_sources();
	if (_feed_collision) {
		_feed(terrain, sources);
	}
	PackedVector3Array positions;
	for (Node3D *node : sources) {
		positions.push_back(node->get_global_position());
	}
	const real_t region_world = real_t(terrain->get_region_size()) * terrain->get_vertex_spacing();

	// 1. What each region wants: everything the index names, plus anything loaded it does not.
	struct Want {
		Vector2i loc;
		real_t key;
	};
	std::vector<Want> loads;
	std::vector<Vector2i> releases;
	std::set<Vector2i, LocLess> locations;
	for (const Vector2i &loc : data->get_region_index()->get_locations()) {
		locations.insert(loc);
	}
	for (const Vector2i &loc : data->get_region_locations()) {
		locations.insert(loc);
	}
	for (const Vector2i &loc : locations) {
		const Ref<Pasture3DRegionType> type = _type_of(loc);
		const real_t load_radius = type.is_valid() ? type->get_load_radius() : 1500.f;
		const real_t unload_radius = type.is_valid() ? MAX(type->get_unload_radius(), load_radius) : 1800.f;
		const int priority = type.is_valid() ? MAX(type->get_priority(), 0) : 0;
		const real_t d = positions.is_empty() ? FLT_MAX : _distance_to(loc, positions, region_world);
		const bool loaded = data->is_region_loaded(loc);
		auto pending = _pending.find(loc);
		if (pending != _pending.end()) {
			if (d > unload_radius) {
				pending->second.dropped = true; // Too far now: finish the read, then discard it
			} else {
				pending->second.dropped = false; // Back in range before it finished
			}
			continue;
		}
		if (!loaded && d <= load_radius && !_failed.count(loc) && !data->get_region_ptr(loc)) {
			loads.push_back({ loc, d / real_t(1 + priority) });
		} else if (loaded && d > unload_radius) {
			releases.push_back(loc);
		}
	}
	std::sort(loads.begin(), loads.end(), [](const Want &a, const Want &b) { return a.key < b.key; });

	// 2. Start reads, nearest first, up to max_pending_loads in flight.
	for (const Want &want : loads) {
		if (int(_pending.size()) >= _max_pending_loads) {
			break;
		}
		_start(terrain, want.loc);
	}
	_poll();

	// 3. Adopt what has been read, nearest first, within the per-frame count and time budget.
	std::vector<Want> ready;
	for (auto it = _pending.begin(); it != _pending.end();) {
		if (it->second.dropped && (it->second.region.is_valid() || _failed.count(it->first))) {
			_dropped += it->second.region.is_valid() ? 1 : 0;
			it = _pending.erase(it);
			continue;
		}
		if (it->second.region.is_valid()) {
			const Ref<Pasture3DRegionType> type = _type_of(it->first);
			const int priority = type.is_valid() ? MAX(type->get_priority(), 0) : 0;
			ready.push_back({ it->first, _distance_to(it->first, positions, region_world) / real_t(1 + priority) });
		}
		++it;
	}
	std::sort(ready.begin(), ready.end(), [](const Want &a, const Want &b) { return a.key < b.key; });
	const int64_t frame_start = Time::get_singleton()->get_ticks_usec();
	const int64_t budget_usec = int64_t(_adopt_budget_msec * 1000.f);
	int adopts = 0;
	for (const Want &want : ready) {
		if (adopts >= _max_adopts_per_frame || (adopts > 0 && Time::get_singleton()->get_ticks_usec() - frame_start >= budget_usec)) {
			break;
		}
		Pending pending = _pending[want.loc];
		_pending.erase(want.loc);
		const Error err = data->adopt_region(want.loc, pending.region, pending.path, pending.legacy, pending.slice, true);
		adopts++;
		if (err != OK) {
			LOG(ERROR, "Adopting region ", want.loc, " failed: ", err);
			_failed.insert(want.loc);
			continue;
		}
		_adopted++;
		_kept.erase(want.loc);
		emit_signal("region_loaded", want.loc);
	}
	const int adopt_usec = int(Time::get_singleton()->get_ticks_usec() - frame_start);
	_last_adopts = adopts;
	_last_adopt_usec = adopts > 0 ? adopt_usec : 0;
	_max_adopts_in_frame = MAX(_max_adopts_in_frame, adopts);
	_max_adopt_usec_in_frame = MAX(_max_adopt_usec_in_frame, _last_adopt_usec);

	// 4. Release what is out of range. Nothing is saved; a region with unsaved changes is kept.
	bool released_any = false;
	int kept_waiting = 0;
	for (const Vector2i &loc : releases) {
		const Error err = data->release_region(loc, false);
		if (err == OK) {
			_released++;
			released_any = true;
			_kept.erase(loc);
			emit_signal("region_unloaded", loc);
		} else if (err == ERR_BUSY) {
			kept_waiting++;
			if (_kept.insert(loc).second) {
				LOG(INFO, "Region ", loc, " is out of range but has changes that are not on disk; keeping it loaded");
				emit_signal("region_kept", loc);
			}
		}
	}
	if (released_any) {
		data->update_maps(TYPE_MAX, false, false); // One region-map upload for all of this frame's releases
	}

	// 5. Idle: nothing to read, nothing read waiting, nothing left to release (a kept region cannot be).
	const bool idle = _pending.empty() && loads.empty() && int(releases.size()) == kept_waiting;
	if (idle && !_idle) {
		emit_signal("streaming_idle");
	}
	_idle = idle;
}

void Pasture3DStreamer::set_enabled(const bool p_enabled) {
	_enabled = p_enabled;
	if (!_enabled) {
		_idle = false;
	}
	_refresh_terrain_warnings();
}

void Pasture3DStreamer::set_terrain(Node *p_terrain) {
	_refresh_terrain_warnings(); // The terrain it leaves
	_terrain.set_target(p_terrain);
	_refresh_terrain_warnings();
}

// The terrain warns when no streamer drives it (Pasture3D::has_streamer), so it has to hear when one arrives,
// leaves, or changes target. Deferred: during EXIT_TREE this node is still in the hierarchy the terrain walks.
void Pasture3DStreamer::_refresh_terrain_warnings() const {
	if (!Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	if (Pasture3D *terrain = _get_terrain()) {
		terrain->call_deferred("update_configuration_warnings");
	}
}

void Pasture3DStreamer::set_sources(const TypedArray<Node3D> &p_sources) {
	_sources.clear();
	for (int i = 0; i < p_sources.size(); i++) {
		TargetNode3D target;
		target.set_target(Object::cast_to<Node3D>(p_sources[i]));
		if (target.is_set()) {
			_sources.push_back(target);
		}
	}
}

TypedArray<Node3D> Pasture3DStreamer::get_sources() const {
	TypedArray<Node3D> nodes;
	for (const TargetNode3D &source : _sources) {
		if (Node3D *node = source.get_target()) {
			nodes.push_back(node);
		}
	}
	return nodes;
}

void Pasture3DStreamer::set_feed_collision(const bool p_feed) {
	_feed_collision = p_feed;
	if (!_feed_collision && !_fed_ids.empty()) {
		_fed_ids.clear();
		if (Pasture3D *terrain = _get_terrain()) {
			terrain->set_collision_targets(TypedArray<Node3D>());
		}
	}
}

Dictionary Pasture3DStreamer::get_stats() const {
	Dictionary stats;
	stats["frames"] = _frames;
	stats["requests"] = _requests;
	stats["threaded_requests"] = _threaded_requests;
	stats["adopted"] = _adopted;
	stats["released"] = _released;
	stats["dropped"] = _dropped;
	stats["failed"] = int(_failed.size());
	stats["kept"] = int(_kept.size());
	stats["pending"] = int(_pending.size());
	stats["max_adopts_in_frame"] = _max_adopts_in_frame;
	stats["max_adopt_usec_in_frame"] = _max_adopt_usec_in_frame;
	stats["last_adopts"] = _last_adopts;
	stats["last_adopt_usec"] = _last_adopt_usec;
	return stats;
}

void Pasture3DStreamer::reset_stats() {
	_frames = _requests = _threaded_requests = _adopted = _released = _dropped = 0;
	_max_adopts_in_frame = _max_adopt_usec_in_frame = _last_adopts = _last_adopt_usec = 0;
}

PackedStringArray Pasture3DStreamer::_get_configuration_warnings() const {
	PackedStringArray warnings;
	const Pasture3D *terrain = _get_terrain();
	if (!terrain) {
		warnings.push_back("Needs a Pasture3D: make it a child of one, or set terrain.");
	} else if (terrain->get_region_loading() == Pasture3D::REGION_LOADING_ALL) {
		warnings.push_back("The terrain's region_loading is All, so the game loads every region at start and then "
						   "releases the far ones. Set it to Auto to start with only the region index.");
	}
	return warnings;
}

///////////////////////////
// Protected Functions
///////////////////////////

void Pasture3DStreamer::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_READY: {
			// Editor streaming is not built: in the editor this node only shows its warnings.
			set_process(!Engine::get_singleton()->is_editor_hint());
			break;
		}
		case NOTIFICATION_ENTER_TREE: {
			_refresh_terrain_warnings();
			break;
		}
		case NOTIFICATION_PROCESS: {
			tick();
			break;
		}
		case NOTIFICATION_EXIT_TREE: {
			_refresh_terrain_warnings();
			if (_feed_collision && !_fed_ids.empty()) {
				_fed_ids.clear();
				if (Pasture3D *terrain = _get_terrain()) {
					terrain->set_collision_targets(TypedArray<Node3D>());
				}
			}
			break;
		}
	}
}

void Pasture3DStreamer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("tick"), &Pasture3DStreamer::tick);
	ClassDB::bind_method(D_METHOD("set_enabled", "enabled"), &Pasture3DStreamer::set_enabled);
	ClassDB::bind_method(D_METHOD("get_enabled"), &Pasture3DStreamer::get_enabled);
	ClassDB::bind_method(D_METHOD("set_terrain", "terrain"), &Pasture3DStreamer::set_terrain);
	ClassDB::bind_method(D_METHOD("get_terrain"), &Pasture3DStreamer::get_terrain);
	ClassDB::bind_method(D_METHOD("set_sources", "sources"), &Pasture3DStreamer::set_sources);
	ClassDB::bind_method(D_METHOD("get_sources"), &Pasture3DStreamer::get_sources);
	ClassDB::bind_method(D_METHOD("set_threaded", "threaded"), &Pasture3DStreamer::set_threaded);
	ClassDB::bind_method(D_METHOD("get_threaded"), &Pasture3DStreamer::get_threaded);
	ClassDB::bind_method(D_METHOD("set_max_pending_loads", "count"), &Pasture3DStreamer::set_max_pending_loads);
	ClassDB::bind_method(D_METHOD("get_max_pending_loads"), &Pasture3DStreamer::get_max_pending_loads);
	ClassDB::bind_method(D_METHOD("set_max_adopts_per_frame", "count"), &Pasture3DStreamer::set_max_adopts_per_frame);
	ClassDB::bind_method(D_METHOD("get_max_adopts_per_frame"), &Pasture3DStreamer::get_max_adopts_per_frame);
	ClassDB::bind_method(D_METHOD("set_adopt_budget_msec", "msec"), &Pasture3DStreamer::set_adopt_budget_msec);
	ClassDB::bind_method(D_METHOD("get_adopt_budget_msec"), &Pasture3DStreamer::get_adopt_budget_msec);
	ClassDB::bind_method(D_METHOD("set_feed_collision", "feed"), &Pasture3DStreamer::set_feed_collision);
	ClassDB::bind_method(D_METHOD("get_feed_collision"), &Pasture3DStreamer::get_feed_collision);
	ClassDB::bind_method(D_METHOD("is_idle"), &Pasture3DStreamer::is_idle);
	ClassDB::bind_method(D_METHOD("get_pending_count"), &Pasture3DStreamer::get_pending_count);
	ClassDB::bind_method(D_METHOD("get_stats"), &Pasture3DStreamer::get_stats);
	ClassDB::bind_method(D_METHOD("reset_stats"), &Pasture3DStreamer::reset_stats);

	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "enabled"), "set_enabled", "get_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "terrain", PROPERTY_HINT_NODE_TYPE, "Pasture3D", PROPERTY_USAGE_DEFAULT, "Node"), "set_terrain", "get_terrain");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "sources", PROPERTY_HINT_TYPE_STRING,
						 String::num_int64(Variant::OBJECT) + "/" + String::num_int64(PROPERTY_HINT_NODE_TYPE) + ":Node3D"),
			"set_sources", "get_sources");
	ADD_GROUP("Loading", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "threaded"), "set_threaded", "get_threaded");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_pending_loads", PROPERTY_HINT_RANGE, "1,32,1"), "set_max_pending_loads", "get_max_pending_loads");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "max_adopts_per_frame", PROPERTY_HINT_RANGE, "1,16,1"), "set_max_adopts_per_frame", "get_max_adopts_per_frame");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "adopt_budget_msec", PROPERTY_HINT_RANGE, "0.0,33.0,0.1"), "set_adopt_budget_msec", "get_adopt_budget_msec");
	ADD_GROUP("Collision", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "feed_collision"), "set_feed_collision", "get_feed_collision");

	ADD_SIGNAL(MethodInfo("region_loaded", PropertyInfo(Variant::VECTOR2I, "region_location")));
	ADD_SIGNAL(MethodInfo("region_unloaded", PropertyInfo(Variant::VECTOR2I, "region_location")));
	ADD_SIGNAL(MethodInfo("region_kept", PropertyInfo(Variant::VECTOR2I, "region_location")));
	ADD_SIGNAL(MethodInfo("streaming_idle"));
}
