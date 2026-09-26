// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
// Distance streaming of terrain regions at runtime.
// Spec: PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md §H (phase 6)

#ifndef PASTURE3D_STREAMER_CLASS_H
#define PASTURE3D_STREAMER_CLASS_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <map>
#include <set>
#include <vector>

#include "constants.h"
#include "target_node_3d.h"

using namespace godot;

class Pasture3D;
class Pasture3DRegionType;

/**
 * Keeps the regions near its sources loaded, and the rest on disk.
 *
 * Each frame, for every region the index names, it takes the distance from the nearest source to the
 * region's footprint. A region closer than its type's load_radius is loaded; one further than its
 * unload_radius is released. The gap between the two is the hysteresis. Loads are queued nearest first,
 * with the distance divided by (1 + the type's priority).
 *
 * The file reads run on ResourceLoader's worker threads. Only the adopt (Pasture3DData::adopt_region:
 * one slot upload and one region-map texel) runs on the main thread, and at most max_adopts_per_frame
 * of those run per frame, stopping early once adopt_budget_msec is spent.
 *
 * A released region is NOT saved (a game never writes its data): one with changes that are not on disk
 * is kept loaded instead, and reported once through region_kept.
 *
 * With feed_collision, the sources become the terrain's collision targets, so every source gets its own
 * DYNAMIC collision patch.
 *
 * Runs only in a game, never in the editor. Set the terrain's load_all_regions off, or the game starts by
 * loading everything and then releases what is far away.
 */
class Pasture3DStreamer : public Node {
	GDCLASS(Pasture3DStreamer, Node);
	CLASS_NAME();

	struct Pending {
		String path;
		String slice_path; // Empty when the region has no layer slice
		bool legacy = false;
		bool threaded = false;
		bool dropped = false; // Its sources left before it finished reading; discard it when it does
		Ref<Resource> region; // Filled when the read is done
		Ref<Resource> slice;
	};
	struct LocLess {
		bool operator()(const Vector2i &a, const Vector2i &b) const { return a.x != b.x ? a.x < b.x : a.y < b.y; }
	};

	bool _enabled = true;
	TargetNode _terrain;
	std::vector<TargetNode3D> _sources;
	bool _threaded = true;
	int _max_pending_loads = 4;
	int _max_adopts_per_frame = 1;
	real_t _adopt_budget_msec = 4.f;
	bool _feed_collision = true;

	std::map<Vector2i, Pending, LocLess> _pending;
	std::set<Vector2i, LocLess> _failed; // Reads that failed: not retried
	std::set<Vector2i, LocLess> _kept; // Released but refused (changes not on disk): reported once
	std::vector<uint64_t> _fed_ids; // The collision targets last handed to the terrain
	bool _idle = false;
	Dictionary _type_cache; // type_path -> Pasture3DRegionType

	// Counters for gates and profiling (get_stats).
	int _frames = 0;
	int _requests = 0;
	int _threaded_requests = 0;
	int _adopted = 0;
	int _released = 0;
	int _dropped = 0;
	int _max_adopts_in_frame = 0;
	int _max_adopt_usec_in_frame = 0;
	int _last_adopts = 0;
	int _last_adopt_usec = 0;

	Pasture3D *_get_terrain() const;
	std::vector<Node3D *> _resolve_sources() const;
	Ref<Pasture3DRegionType> _type_of(const Vector2i &p_loc) const;
	real_t _distance_to(const Vector2i &p_loc, const PackedVector3Array &p_positions, const real_t p_region_world) const;
	void _feed(Pasture3D *p_terrain, const std::vector<Node3D *> &p_sources);
	bool _start(Pasture3D *p_terrain, const Vector2i &p_loc);
	void _poll();

public:
	Pasture3DStreamer() {}

	// One streaming step. Called every frame in a game; a gate can call it directly.
	void tick();

	void set_enabled(const bool p_enabled);
	bool get_enabled() const { return _enabled; }
	void set_terrain(Node *p_terrain) { _terrain.set_target(p_terrain); }
	Node *get_terrain() const { return _terrain.get_target(); }
	void set_sources(const TypedArray<Node3D> &p_sources);
	TypedArray<Node3D> get_sources() const;
	void set_threaded(const bool p_threaded) { _threaded = p_threaded; }
	bool get_threaded() const { return _threaded; }
	void set_max_pending_loads(const int p_count) { _max_pending_loads = MAX(1, p_count); }
	int get_max_pending_loads() const { return _max_pending_loads; }
	void set_max_adopts_per_frame(const int p_count) { _max_adopts_per_frame = MAX(1, p_count); }
	int get_max_adopts_per_frame() const { return _max_adopts_per_frame; }
	void set_adopt_budget_msec(const real_t p_msec) { _adopt_budget_msec = MAX(real_t(0.f), p_msec); }
	real_t get_adopt_budget_msec() const { return _adopt_budget_msec; }
	void set_feed_collision(const bool p_feed);
	bool get_feed_collision() const { return _feed_collision; }

	bool is_idle() const { return _idle; }
	int get_pending_count() const { return int(_pending.size()); }
	Dictionary get_stats() const;
	void reset_stats();

	PackedStringArray _get_configuration_warnings() const;

protected:
	void _notification(int p_what);
	static void _bind_methods();
};

#endif // PASTURE3D_STREAMER_CLASS_H
