// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef PASTURE3D_REGION_INDEX_CLASS_H
#define PASTURE3D_REGION_INDEX_CLASS_H

#include <godot_cpp/classes/resource.hpp>

#include "constants.h"

using namespace godot;

// Every region that exists on disk, whether or not it is loaded (PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md
// §A). Pasture3DData::_regions only holds LOADED regions, so once a region can be unloaded something else
// has to remember that it exists: the region gizmo draws unloaded regions from here, a bake finds the
// regions it must load from here, and a reload compares the layer-stack signature recorded here to decide
// whether the region's composite went stale while it was away.
//
// Saved as pasture3d_region_index.res beside the region files. Missing on data written before it existed;
// load_directory rebuilds it from the region files it loads.
class Pasture3DRegionIndex : public Resource {
	GDCLASS(Pasture3DRegionIndex, Resource);
	CLASS_NAME();

	real_t _version = 1.f;
	// entries[region_location:Vector2i] -> Dictionary {
	//   "height_range": Vector2,     // min/max height, so an unloaded region can still be drawn and culled
	//   "stack_signature": int,      // Pasture3DData::_stack_signature() when the region was last written
	// }
	Dictionary _entries;

public:
	void set_version(const real_t p_version) { _version = p_version; }
	real_t get_version() const { return _version; }
	void set_entries(const Dictionary &p_entries) { _entries = p_entries; }
	Dictionary get_entries() const { return _entries; }

	bool has_entry(const Vector2i &p_region_loc) const { return _entries.has(p_region_loc); }
	Dictionary get_entry(const Vector2i &p_region_loc) const { return _entries.get(p_region_loc, Dictionary()); }
	void set_entry(const Vector2i &p_region_loc, const Dictionary &p_entry) { _entries[p_region_loc] = p_entry; }
	void erase_entry(const Vector2i &p_region_loc) { _entries.erase(p_region_loc); }
	TypedArray<Vector2i> get_locations() const { return _entries.keys(); }

protected:
	static void _bind_methods();
};

#endif // PASTURE3D_REGION_INDEX_CLASS_H
