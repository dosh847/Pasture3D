// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/height_map_shape3d.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <unordered_map>

#include <godot_cpp/classes/scene_tree.hpp>

#include "constants.h"
#include "logger.h"
#include "pasture_3d.h"
#include "pasture_3d_collision.h"
#include "pasture_3d_data.h"
#include "pasture_3d_util.h"

///////////////////////////
// Private Functions
///////////////////////////

// Calculates shape data from top left position. Assumes descaled and snapped.
Dictionary Pasture3DCollision::_get_shape_data(const Vector2i &p_position, const int p_size) {
	IS_DATA_INIT_MESG("Terrain not initialized", Dictionary());
	const Pasture3DData *data = _terrain->get_data();

	const Ref<Pasture3DMaterial> material = _terrain->get_material();
	if (!material.is_valid()) {
		return Dictionary();
	}
	const Pasture3DMaterial::WorldBackground bg_mode = material->get_world_background();
	const bool is_bg_flat_or_noise = bg_mode == Pasture3DMaterial::WorldBackground::FLAT || bg_mode == Pasture3DMaterial::WorldBackground::NOISE;
	const real_t ground_level = material->get("ground_level");
	const real_t region_blend = material->get("region_blend");
	const int region_map_size = Pasture3DData::get_region_map_size();
	const PackedInt32Array region_map = data->get_region_map();
	const int region_size = _terrain->get_region_size();
	const real_t region_texel_size = 1.f / real_t(region_size);

	auto check_region = [&](const Vector2 &uv2) -> real_t {
		Vector2i pos = Vector2i(Math::floor(uv2.x), Math::floor(uv2.y)) + Vector2i(region_map_size / 2, region_map_size / 2);
		int layer_index = 0;
		if ((uint32_t)(pos.x | pos.y) < (uint32_t)region_map_size) {
			const int slot = Pasture3DData::region_map_decode(region_map[pos.y * region_map_size + pos.x]);
			layer_index = slot >= 0 ? 1 : 0;
		}
		return real_t(layer_index);
	};

	auto get_region_blend = [&](Vector2 uv2) -> real_t {
		// Floating point bias (must match shader)
		uv2 -= Vector2(0.5011f, 0.5011f);

		real_t a = check_region(uv2 + Vector2(0.0f, 1.0f));
		real_t b = check_region(uv2 + Vector2(1.0f, 1.0f));
		real_t c = check_region(uv2 + Vector2(1.0f, 0.0f));
		real_t d = check_region(uv2 + Vector2(0.0f, 0.0f));

		real_t blend_factor = 2.0f + 126.0f * (1.0f - region_blend);
		Vector2 f = Vector2(uv2.x - Math::floor(uv2.x), uv2.y - Math::floor(uv2.y));
		f.x = Math::clamp(f.x, real_t(1e-8f), real_t(1.0f - 1e-8f));
		f.y = Math::clamp(f.y, real_t(1e-8f), real_t(1.0f - 1e-8f));
		Vector2 w = Vector2(1.f / (1.f + Math::exp(blend_factor * Math::log((1.f - f.x) / f.x))),
				1.f / (1.f + Math::exp(blend_factor * Math::log((1.f - f.y) / f.y))));
		real_t blend = Math::lerp(Math::lerp(d, c, w.x), Math::lerp(a, b, w.x), w.y);

		return (1.f - blend) * 2.f;
	};

	int hshape_size = p_size + 1; // Calculate last vertex at end
	PackedRealArray map_data = PackedRealArray();
	map_data.resize(hshape_size * hshape_size);
	real_t min_height = FLT_MAX;
	real_t max_height = -FLT_MAX;

	// Get region_loc of top left corner of descaled and grid snapped collision shape position
	Vector2i region_loc = V2I_DIVIDE_FLOOR(p_position, region_size);
	const Pasture3DRegion *region = data->get_region_ptr(region_loc);
	if (!region || region->is_deleted()) {
		LOG(EXTREME, "Region not found at: ", region_loc, ". Returning blank");
		return Dictionary();
	}

	// This region and the +X, +Z, +XZ neighbours the last row/col runs over, indexed x + 2z. A region whose
	// type has collision off contributes holes (NaN). A coarse one is read through get_height_at_vertex, which
	// interpolates its lattice; a Standard one is read straight from its maps.
	struct Source {
		const Image *map = nullptr;
		const Image *cmap = nullptr;
		int ratio = 1;
		bool active = false;
	};
	Source src[4];
	for (int q = 0; q < 4; q++) {
		const Pasture3DRegion *r = data->get_region_ptr(region_loc + Vector2i(q & 1, q >> 1));
		if (!r || r->is_deleted() || !data->region_has_collision(r)) {
			continue;
		}
		src[q].map = r->get_map_ptr(TYPE_HEIGHT);
		src[q].cmap = r->get_map_ptr(TYPE_CONTROL);
		src[q].ratio = r->get_texel_ratio();
		src[q].active = src[q].map && src[q].cmap;
	}

	for (int z = 0; z < hshape_size; z++) {
		for (int x = 0; x < hshape_size; x++) {
			// Choose array indexing to match triangulation of heightmapshape with the mesh
			// https://stackoverflow.com/questions/16684856/rotating-a-2d-pixel-array-by-90-degrees
			// Normal array index rotated Y=0 - shape rotation Y=0 (xform below)
			// int index = z * hshape_size + x;
			// Array Index Rotated Y=-90 - must rotate shape Y=+90 (xform below)
			int index = hshape_size - 1 - z + x * hshape_size;

			Vector2i shape_pos = p_position + Vector2i(x, z);
			Vector2i shape_region_loc = V2I_DIVIDE_FLOOR(shape_pos, region_size);
			int img_x = Math::posmod(shape_pos.x, region_size);
			bool next_x = shape_region_loc.x > region_loc.x;
			int img_y = Math::posmod(shape_pos.y, region_size);
			bool next_z = shape_region_loc.y > region_loc.y;

			// Set heights on local map, or adjacent maps if on the last row/col
			real_t height = NAN;
			const Source &s = src[(next_x ? 1 : 0) + (next_z ? 2 : 0)];
			if (s.active) {
				if (s.ratio > 1) {
					height = is_hole(s.cmap->get_pixel(img_x / s.ratio, img_y / s.ratio).r) ? NAN : data->get_height_at_vertex(shape_pos);
				} else {
					height = is_hole(s.cmap->get_pixel(img_x, img_y).r) ? NAN : s.map->get_pixel(img_x, img_y).r;
				}
			}
			if (!std::isnan(height) && is_bg_flat_or_noise) {
				Vector2 uv2 = Vector2(shape_pos) * region_texel_size;
				height = Math::lerp(height, ground_level, smoothstep(0.f, 1.f, get_region_blend(uv2)));
			}
			map_data[index] = height;
			if (!std::isnan(height)) {
				min_height = MIN(min_height, height);
				max_height = MAX(max_height, height);
			}
		}
	}

	// Non rotated shape for normal array index above
	//Transform3D xform = Transform3D(Basis(), global_pos);
	// Rotated shape Y=90 for -90 rotated array index
	Transform3D xform = Transform3D(Basis(V3_UP, Math_PI * .5), v2iv3(p_position + V2I(p_size / 2)));
	Dictionary shape_data;
	shape_data["width"] = hshape_size;
	shape_data["depth"] = hshape_size;
	shape_data["heights"] = map_data;
	shape_data["xform"] = xform;
	// All holes (a collision-off region): an empty range, not FLT_MAX..-FLT_MAX.
	shape_data["min_height"] = min_height <= max_height ? min_height : 0.f;
	shape_data["max_height"] = min_height <= max_height ? max_height : 0.f;
	return shape_data;
}

void Pasture3DCollision::_shape_set_disabled(const int p_shape_id, const bool p_disabled) {
	if (is_editor_mode()) {
		CollisionShape3D *shape = _shapes[p_shape_id];
		shape->set_disabled(p_disabled);
		shape->set_visible(!p_disabled);
	} else {
		PS->body_set_shape_disabled(_static_body_rid, p_shape_id, p_disabled);
	}
}

void Pasture3DCollision::_shape_set_transform(const int p_shape_id, const Transform3D &p_xform) {
	if (is_editor_mode()) {
		CollisionShape3D *shape = _shapes[p_shape_id];
		shape->set_transform(p_xform);
	} else {
		PS->body_set_shape_transform(_static_body_rid, p_shape_id, p_xform);
	}
}

Vector3 Pasture3DCollision::_shape_get_position(const int p_shape_id) const {
	if (is_editor_mode()) {
		return _shapes[p_shape_id]->get_global_position();
	} else {
		return PS->body_get_shape_transform(_static_body_rid, p_shape_id).origin;
	}
}

void Pasture3DCollision::_shape_set_data(const int p_shape_id, const Dictionary &p_dict) {
	if (is_editor_mode()) {
		CollisionShape3D *shape = _shapes[p_shape_id];
		Ref<HeightMapShape3D> hshape = shape->get_shape();
		hshape->set_map_data(p_dict["heights"]);
	} else {
		RID shape_rid = PS->body_get_shape(_static_body_rid, p_shape_id);
		PS->shape_set_data(shape_rid, p_dict);
	}
}

void Pasture3DCollision::_reload_physics_material() {
	if (is_editor_mode()) {
		if (_static_body) {
			_static_body->set_physics_material_override(_physics_material);
		}
	} else {
		if (_static_body_rid.is_valid()) {
			if (_physics_material.is_null()) {
				PS->body_set_param(_static_body_rid, PhysicsServer3D::BODY_PARAM_BOUNCE, 0.f);
				PS->body_set_param(_static_body_rid, PhysicsServer3D::BODY_PARAM_FRICTION, 1.f);
			} else {
				real_t computed_bounce = _physics_material->get_bounce() * (_physics_material->is_absorbent() ? -1.f : 1.f);
				real_t computed_friction = _physics_material->get_friction() * (_physics_material->is_rough() ? -1.f : 1.f);
				PS->body_set_param(_static_body_rid, PhysicsServer3D::BODY_PARAM_BOUNCE, computed_bounce);
				PS->body_set_param(_static_body_rid, PhysicsServer3D::BODY_PARAM_FRICTION, computed_friction);
			}
		}
	}
	if (_physics_material.is_valid()) {
		LOG(DEBUG, "Setting PhysicsMaterial bounce: ", _physics_material->get_bounce(), ", friction: ", _physics_material->get_friction());
	}
}

///////////////////////////
// Public Functions
///////////////////////////

void Pasture3DCollision::initialize(Pasture3D *p_terrain) {
	if (p_terrain) {
		_terrain = p_terrain;
	} else {
		return;
	}
	if (!IS_EDITOR && is_editor_mode()) {
		LOG(WARN, "Change collision mode to a non-editor mode for releases");
	}
	build();
}

void Pasture3DCollision::build() {
	IS_DATA_INIT(VOID);
	if (!_terrain->is_inside_world()) {
		LOG(ERROR, "Terrain isn't inside world. Returning.");
		return;
	}

	// Clear collision as the user might change modes in the editor
	destroy();

	// Build only in applicable modes
	if (!is_enabled() || (IS_EDITOR && !is_editor_mode())) {
		return;
	}

	// Create StaticBody3D
	if (is_editor_mode()) {
		LOG(INFO, "Building editor collision");
		_static_body = memnew(StaticBody3D);
		_static_body->set_name("StaticBody3D");
		_static_body->set_as_top_level(true);
		_terrain->add_child(_static_body, true);
		_static_body->set_owner(_terrain);
		_static_body->set_collision_mask(_mask);
		_static_body->set_collision_layer(_layer);
		_static_body->set_collision_priority(_priority);
	} else {
		LOG(INFO, "Building collision with Physics Server");
		_static_body_rid = PS->body_create();
		PS->body_set_mode(_static_body_rid, PhysicsServer3D::BODY_MODE_STATIC);
		PS->body_set_space(_static_body_rid, _terrain->get_world_3d()->get_space());
		PS->body_attach_object_instance_id(_static_body_rid, _terrain->get_instance_id());
		PS->body_set_collision_mask(_static_body_rid, _mask);
		PS->body_set_collision_layer(_static_body_rid, _layer);
		PS->body_set_collision_priority(_static_body_rid, _priority);
	}
	_reload_physics_material();

	// Create CollisionShape3Ds
	int shape_count;
	int hshape_size;
	if (is_dynamic_mode()) {
		int grid_width = _radius * 2 / _shape_size;
		grid_width = int_ceil_pow2(grid_width, 4);
		_pool_targets = MAX(1, int(_terrain->get_collision_target_positions().size()));
		shape_count = grid_width * grid_width * _pool_targets;
		hshape_size = _shape_size + 1;
		LOG(DEBUG, "Grid width: ", grid_width);
	} else {
		shape_count = _terrain->get_data()->get_region_count();
		hshape_size = _terrain->get_region_size() + 1;
	}
	// Preallocate memory for push_back()
	if (is_editor_mode()) {
		_shapes.reserve(shape_count);
	}
	LOG(DEBUG, "Shape count: ", shape_count);
	LOG(DEBUG, "Shape size: ", _shape_size, ", hshape_size: ", hshape_size);
	Transform3D xform(Basis(), V3_MAX);
	for (int i = 0; i < shape_count; i++) {
		if (is_editor_mode()) {
			CollisionShape3D *col_shape = memnew(CollisionShape3D);
			_shapes.push_back(col_shape);
			col_shape->set_name("CollisionShape3D");
			col_shape->set_disabled(true);
			col_shape->set_visible(true);
			col_shape->set_enable_debug_fill(false);
			Ref<HeightMapShape3D> hshape;
			hshape.instantiate();
			hshape->set_map_width(hshape_size);
			hshape->set_map_depth(hshape_size);
			col_shape->set_shape(hshape);
			_static_body->add_child(col_shape, true);
			col_shape->set_owner(_static_body);
			col_shape->set_transform(xform);
		} else {
			RID shape_rid = PS->heightmap_shape_create();
			PS->body_add_shape(_static_body_rid, shape_rid, xform, true);
			LOG(DEBUG, "Adding shape: ", i, ", rid: ", shape_rid.get_id(), " pos: ", _shape_get_position(i));
		}
	}

	_initialized = true;
	_region_sig = _snapshot_regions();
	update();
}

void Pasture3DCollision::update(const Vector2i &p_region_loc, const bool p_rebuild) {
	IS_INIT(VOID);
	if (!_initialized) {
		return;
	}
	if (p_rebuild && !is_dynamic_mode()) {
		build();
		return;
	}
	int time = Time::get_singleton()->get_ticks_usec();
	real_t spacing = _terrain->get_vertex_spacing();

	if (is_dynamic_mode()) {
		const PackedVector3Array targets = _terrain->get_collision_target_positions();
		const int target_count = MAX(1, int(targets.size()));
		if (target_count != _pool_targets) {
			// One patch's worth of shapes per target: a new target count means a new pool.
			_pool_targets = target_count;
			build();
			return;
		}
		// Snap each descaled target position to a _shape_size grid (eg. multiples of 16)
		std::vector<Vector2i> snapped;
		for (int t = 0; t < targets.size(); t++) {
			snapped.push_back(_snap_to_grid(targets[t] / spacing));
		}
		if (snapped.empty()) {
			snapped.push_back(_snap_to_grid(V3_ZERO));
		}
		// Return if no target has moved to the next grid slot and no region under a patch changed
		if (!p_rebuild && _changed_regions.empty() && snapped == _last_snapped) {
			return;
		}

		// 1. The cells wanted: every _shape_size cell whose centre lies within _radius of any target, keyed by
		// its top left corner. Overlapping patches share cells, so the pool (one patch per target) suffices.
		int grid_width = _radius * 2 / _shape_size; // 64*2/16 = 8
		grid_width = int_ceil_pow2(grid_width, 4);
		const Vector2i grid_offset = -V2I(grid_width / 2); // offset # cells to center of grid
		const real_t radius_sqr = real_t(_radius * _radius);
		const Vector2i shape_offset = V2I(_shape_size / 2); // offset meters to top left corner of shape
		auto key_of = [](const Vector2i &p) -> int64_t { return (int64_t(p.x) << 32) ^ int64_t(uint32_t(p.y)); };
		std::unordered_map<int64_t, int> wanted; // key -> shape id holding it, or -1
		std::vector<Vector2i> wanted_order;
		for (const Vector2i &centre : snapped) {
			const Vector2i grid_corner = centre + grid_offset * _shape_size; // Top left of grid
			for (int i = 0; i < grid_width * grid_width; i++) {
				const Vector2i shape_pos = grid_corner + Vector2i(i % grid_width, i / grid_width) * _shape_size;
				if ((shape_pos + shape_offset).distance_squared_to(centre) > radius_sqr) {
					continue;
				}
				if (wanted.emplace(key_of(shape_pos), -1).second) {
					wanted_order.push_back(shape_pos);
				}
			}
		}
		// A shape reads its region and the +X/+Z neighbours (its last row and column), so it is stale when its
		// footprint, last vertex included, touches a region that was loaded or unloaded.
		const int region_size = _terrain->get_region_size();
		auto stale = [&](const Vector2i &shape_pos) -> bool {
			for (const Vector2i &loc : _changed_regions) {
				const Vector2i lo = loc * region_size;
				const Vector2i hi = lo + V2I(region_size);
				if (shape_pos.x <= hi.x && shape_pos.x + _shape_size >= lo.x && shape_pos.y <= hi.y &&
						shape_pos.y + _shape_size >= lo.y) {
					return true;
				}
			}
			return false;
		};

		// 2. Keep every active shape that is still wanted and not stale; free the rest.
		std::vector<int> inactive_shape_ids;
		const int shape_count = is_editor_mode() ? int(_shapes.size()) : PS->body_get_shape_count(_static_body_rid);
		for (int i = 0; i < shape_count; i++) {
			const Vector3 shape_global_pos = _shape_get_position(i);
			if (!p_rebuild && shape_global_pos.x < 1e20f) {
				// Unique key: Top left corner of shape, snapped to grid
				const Vector2i shape_pos = _snap_to_grid(v3v2i(shape_global_pos / spacing) - shape_offset);
				auto it = wanted.find(key_of(shape_pos));
				if (it != wanted.end() && it->second < 0 && !stale(shape_pos)) {
					it->second = i;
					_shape_set_disabled(i, false);
					continue;
				}
			}
			inactive_shape_ids.push_back(i);
			_shape_set_disabled(i, true);
			// Park it, so a disabled shape is never mistaken for one still holding its old cell.
			_shape_set_transform(i, Transform3D(Basis(), V3_MAX));
		}

		// 3. Form a shape for every wanted cell nobody holds. A cell over no loaded region stays empty, and is
		// tried again when a region is loaded under it (region_changed) or a target moves.
		int built = 0;
		for (const Vector2i &shape_pos : wanted_order) {
			if (wanted[key_of(shape_pos)] >= 0) {
				continue;
			}
			if (inactive_shape_ids.empty()) {
				LOG(ERROR, "No more unused shapes! Aborting!");
				break;
			}
			Dictionary shape_data = _get_shape_data(shape_pos, _shape_size);
			if (shape_data.is_empty()) {
				continue;
			}
			const int shape_id = inactive_shape_ids.back();
			inactive_shape_ids.pop_back();
			Transform3D xform = shape_data["xform"];
			xform.scale(Vector3(spacing, 1.f, spacing));
			_shape_set_transform(shape_id, xform);
			_shape_set_disabled(shape_id, false);
			_shape_set_data(shape_id, shape_data);
			wanted[key_of(shape_pos)] = shape_id;
			built++;
		}
		_last_snapped = snapped;
		_changed_regions.clear();
		_last_update_built = built;
		LOG(EXTREME, "Collision: ", int(snapped.size()), " targets, ", int(wanted.size()), " cells, built ", built,
				", free ", int(inactive_shape_ids.size()));

	} else {
		// Full collision
		int shape_count = _terrain->get_data()->get_region_count();
		int region_size = _terrain->get_region_size();
		TypedArray<Vector2i> region_locs = _terrain->get_data()->get_region_locations();
		for (int i = 0; i < region_locs.size(); i++) {
			Vector2i region_loc = region_locs[i];
			if (p_region_loc != V2I_MAX && region_loc != p_region_loc) {
				continue;
			}
			Vector2i shape_pos = region_loc * region_size;
			Dictionary shape_data = _get_shape_data(shape_pos, region_size);
			if (shape_data.is_empty()) {
				LOG(ERROR, "Can't get shape data for ", region_loc);
				continue;
			}
			Transform3D xform = shape_data["xform"];
			xform.scale(Vector3(spacing, 1.f, spacing));
			_shape_set_transform(i, xform);
			_shape_set_disabled(i, false);
			_shape_set_data(i, shape_data);
		}
	}
	_last_update_usec = Time::get_singleton()->get_ticks_usec() - time;
	LOG(EXTREME, "Collision update time: ", _last_update_usec, " us");
}

void Pasture3DCollision::destroy() {
	_initialized = false;
	_last_snapped.clear();
	_changed_regions.clear();

	// Physics Server
	if (_static_body_rid.is_valid()) {
		// Shape IDs change as they are freed, so it's not safe to iterate over them while freeing.
		while (PS->body_get_shape_count(_static_body_rid) > 0) {
			RID rid = PS->body_get_shape(_static_body_rid, 0);
			LOG(DEBUG, "Freeing CollisionShape RID ", rid);
			PS->free_rid(rid);
		}

		LOG(DEBUG, "Freeing StaticBody RID");
		PS->free_rid(_static_body_rid);
		_static_body_rid = RID();
	}

	// Scene Tree
	for (int i = 0; i < _shapes.size(); i++) {
		CollisionShape3D *shape = _shapes[i];
		LOG(DEBUG, "Freeing CollisionShape3D ", i, " ", shape->get_name());
		remove_from_tree(shape);
		memdelete_safely(shape);
	}
	_shapes.clear();
	if (_static_body) {
		LOG(DEBUG, "Freeing StaticBody3D");
		remove_from_tree(_static_body);
		memdelete_safely(_static_body);
	}
}

std::map<Vector2i, uint64_t, Pasture3DCollision::LocLess> Pasture3DCollision::_snapshot_regions() const {
	std::map<Vector2i, uint64_t, LocLess> sig;
	const Pasture3DData *data = _terrain->get_data();
	for (const Vector2i &loc : data->get_region_locations()) {
		const Pasture3DRegion *region = data->get_region_ptr(loc);
		if (!region || region->is_deleted()) {
			continue;
		}
		sig[loc] = (region->get_instance_id() * 31u + uint64_t(region->get_texel_ratio())) * 2u +
				(data->region_has_collision(region) ? 1u : 0u);
	}
	return sig;
}

void Pasture3DCollision::on_region_map_changed() {
	if (!_initialized) {
		return;
	}
	if (!is_dynamic_mode()) {
		build(); // One shape per loaded region: the count may have changed
		return;
	}
	// Rebuilding the whole pool here (as this once did) re-created every shape on every region load.
	std::map<Vector2i, uint64_t, LocLess> now = _snapshot_regions();
	for (const auto &[loc, sig] : now) {
		auto it = _region_sig.find(loc);
		if (it == _region_sig.end() || it->second != sig) {
			_changed_regions.push_back(loc);
		}
	}
	for (const auto &[loc, sig] : _region_sig) {
		if (!now.count(loc)) {
			_changed_regions.push_back(loc);
		}
	}
	_region_sig = now;
}

void Pasture3DCollision::region_changed(const Vector2i &p_region_loc) {
	if (!_initialized) {
		return;
	}
	if (is_dynamic_mode()) {
		_changed_regions.push_back(p_region_loc); // Picked up by the next update, in the physics tick
	} else {
		build(); // One shape per loaded region: the count changed
	}
}

Dictionary Pasture3DCollision::get_stats() const {
	Dictionary stats;
	int active = 0;
	int pool = 0;
	if (_initialized) {
		pool = is_editor_mode() ? int(_shapes.size()) : PS->body_get_shape_count(_static_body_rid);
		for (int i = 0; i < pool; i++) {
			// The physics server cannot report a shape disabled; every disabled shape is parked at V3_MAX.
			active += _shape_get_position(i).x < 1e20f ? 1 : 0;
		}
	}
	stats["usec"] = _last_update_usec;
	stats["built"] = _last_update_built;
	stats["active"] = active;
	stats["pool"] = pool;
	stats["targets"] = int(_last_snapped.size());
	return stats;
}

void Pasture3DCollision::set_mode(const CollisionMode p_mode) {
	SET_IF_DIFF(_mode, p_mode);
	LOG(INFO, "Setting collision mode: ", p_mode);
	if (is_enabled()) {
		build();
	} else {
		destroy();
	}
}

void Pasture3DCollision::set_shape_size(const uint16_t p_size) {
	uint16_t size = CLAMP(p_size, 8, 64);
	size = int_round_mult(size, uint16_t(8));
	SET_IF_DIFF(_shape_size, size);
	LOG(INFO, "Setting collision dynamic shape size: ", _shape_size);
	// Ensure size:radius always results in at least one valid shape
	if (_shape_size > _radius - 8) {
		set_radius(_shape_size + 16);
	} else if (is_dynamic_mode()) {
		build();
	}
}

void Pasture3DCollision::set_radius(const uint16_t p_radius) {
	uint16_t radius = CLAMP(p_radius, 16, 256);
	radius = int_ceil_pow2(radius, uint16_t(16));
	SET_IF_DIFF(_radius, radius);
	LOG(INFO, "Setting collision dynamic radius: ", _radius);
	// Ensure size:radius always results in at least one valid shape
	if (_radius < _shape_size + 8) {
		set_shape_size(_radius - 8);
	} else if (_shape_size < 16 && _radius > 128) {
		set_shape_size(16);
	} else if (is_dynamic_mode()) {
		build();
	}
}

void Pasture3DCollision::set_layer(const uint32_t p_layers) {
	SET_IF_DIFF(_layer, p_layers);
	LOG(INFO, "Setting collision layers: ", p_layers);
	if (is_editor_mode()) {
		if (_static_body) {
			_static_body->set_collision_layer(_layer);
		}
	} else {
		if (_static_body_rid.is_valid()) {
			PS->body_set_collision_layer(_static_body_rid, _layer);
		}
	}
}

void Pasture3DCollision::set_mask(const uint32_t p_mask) {
	SET_IF_DIFF(_mask, p_mask);
	LOG(INFO, "Setting collision mask: ", p_mask);
	if (is_editor_mode()) {
		if (_static_body) {
			_static_body->set_collision_mask(_mask);
		}
	} else {
		if (_static_body_rid.is_valid()) {
			PS->body_set_collision_mask(_static_body_rid, _mask);
		}
	}
}

void Pasture3DCollision::set_priority(const real_t p_priority) {
	SET_IF_DIFF(_priority, p_priority);
	LOG(INFO, "Setting collision priority: ", p_priority);
	if (is_editor_mode()) {
		if (_static_body) {
			_static_body->set_collision_priority(_priority);
		}
	} else {
		if (_static_body_rid.is_valid()) {
			PS->body_set_collision_priority(_static_body_rid, _priority);
		}
	}
}

void Pasture3DCollision::set_physics_material(const Ref<PhysicsMaterial> &p_mat) {
	if (_physics_material == p_mat) {
		return;
	}
	if (_physics_material.is_valid()) {
		if (_physics_material->is_connected("changed", callable_mp(this, &Pasture3DCollision::_reload_physics_material))) {
			LOG(DEBUG, "Disconnecting _physics_material::changed signal to _reload_physics_material()");
			_physics_material->disconnect("changed", callable_mp(this, &Pasture3DCollision::_reload_physics_material));
		}
	}
	_physics_material = p_mat;
	LOG(INFO, "Setting physics material: ", p_mat);
	if (_physics_material.is_valid()) {
		LOG(DEBUG, "Connecting _physics_material::changed signal to _reload_physics_material()");
		_physics_material->connect("changed", callable_mp(this, &Pasture3DCollision::_reload_physics_material));
	}
	_reload_physics_material();
}

RID Pasture3DCollision::get_rid() const {
	if (!is_editor_mode()) {
		return _static_body_rid;
	} else {
		if (_static_body) {
			return _static_body->get_rid();
		}
	}
	return RID();
}

///////////////////////////
// Protected Functions
///////////////////////////

void Pasture3DCollision::_bind_methods() {
	BIND_ENUM_CONSTANT(DISABLED);
	BIND_ENUM_CONSTANT(DYNAMIC_GAME);
	BIND_ENUM_CONSTANT(DYNAMIC_EDITOR);
	BIND_ENUM_CONSTANT(FULL_GAME);
	BIND_ENUM_CONSTANT(FULL_EDITOR);

	ClassDB::bind_method(D_METHOD("build"), &Pasture3DCollision::build);
	ClassDB::bind_method(D_METHOD("update", "region_location", "rebuild"), &Pasture3DCollision::update, DEFVAL(V2I_MAX), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("destroy"), &Pasture3DCollision::destroy);
	ClassDB::bind_method(D_METHOD("region_changed", "region_location"), &Pasture3DCollision::region_changed);
	ClassDB::bind_method(D_METHOD("get_stats"), &Pasture3DCollision::get_stats);
	ClassDB::bind_method(D_METHOD("set_mode", "mode"), &Pasture3DCollision::set_mode);
	ClassDB::bind_method(D_METHOD("get_mode"), &Pasture3DCollision::get_mode);
	ClassDB::bind_method(D_METHOD("is_enabled"), &Pasture3DCollision::is_enabled);
	ClassDB::bind_method(D_METHOD("is_editor_mode"), &Pasture3DCollision::is_editor_mode);
	ClassDB::bind_method(D_METHOD("is_dynamic_mode"), &Pasture3DCollision::is_dynamic_mode);

	ClassDB::bind_method(D_METHOD("set_shape_size", "size"), &Pasture3DCollision::set_shape_size);
	ClassDB::bind_method(D_METHOD("get_shape_size"), &Pasture3DCollision::get_shape_size);
	ClassDB::bind_method(D_METHOD("set_radius", "radius"), &Pasture3DCollision::set_radius);
	ClassDB::bind_method(D_METHOD("get_radius"), &Pasture3DCollision::get_radius);
	ClassDB::bind_method(D_METHOD("set_layer", "layers"), &Pasture3DCollision::set_layer);
	ClassDB::bind_method(D_METHOD("get_layer"), &Pasture3DCollision::get_layer);
	ClassDB::bind_method(D_METHOD("set_mask", "mask"), &Pasture3DCollision::set_mask);
	ClassDB::bind_method(D_METHOD("get_mask"), &Pasture3DCollision::get_mask);
	ClassDB::bind_method(D_METHOD("set_priority", "priority"), &Pasture3DCollision::set_priority);
	ClassDB::bind_method(D_METHOD("get_priority"), &Pasture3DCollision::get_priority);
	ClassDB::bind_method(D_METHOD("set_physics_material", "material"), &Pasture3DCollision::set_physics_material);
	ClassDB::bind_method(D_METHOD("get_physics_material"), &Pasture3DCollision::get_physics_material);
	ClassDB::bind_method(D_METHOD("get_rid"), &Pasture3DCollision::get_rid);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "mode", PROPERTY_HINT_ENUM, "Disabled,Dynamic / Game,Dynamic / Editor,Full / Game,Full / Editor"), "set_mode", "get_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "shape_size", PROPERTY_HINT_RANGE, "8,64,8"), "set_shape_size", "get_shape_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "radius", PROPERTY_HINT_RANGE, "16,256,16"), "set_radius", "get_radius");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "layer", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_layer", "get_layer");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_mask", "get_mask");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "priority", PROPERTY_HINT_RANGE, "0.1,256,.1"), "set_priority", "get_priority");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "physics_material", PROPERTY_HINT_RESOURCE_TYPE, "PhysicsMaterial"), "set_physics_material", "get_physics_material");
}
