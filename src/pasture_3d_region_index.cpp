// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_region_index.h"

void Pasture3DRegionIndex::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_version", "version"), &Pasture3DRegionIndex::set_version);
	ClassDB::bind_method(D_METHOD("get_version"), &Pasture3DRegionIndex::get_version);
	ClassDB::bind_method(D_METHOD("set_entries", "entries"), &Pasture3DRegionIndex::set_entries);
	ClassDB::bind_method(D_METHOD("get_entries"), &Pasture3DRegionIndex::get_entries);
	ClassDB::bind_method(D_METHOD("has_entry", "region_location"), &Pasture3DRegionIndex::has_entry);
	ClassDB::bind_method(D_METHOD("get_entry", "region_location"), &Pasture3DRegionIndex::get_entry);
	ClassDB::bind_method(D_METHOD("get_locations"), &Pasture3DRegionIndex::get_locations);
	ClassDB::bind_method(D_METHOD("set_region_size", "size"), &Pasture3DRegionIndex::set_region_size);
	ClassDB::bind_method(D_METHOD("get_region_size"), &Pasture3DRegionIndex::get_region_size);

	int ro_flags = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "version", PROPERTY_HINT_NONE, "", ro_flags), "set_version", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "entries", PROPERTY_HINT_NONE, "", ro_flags), "set_entries", "get_entries");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "region_size", PROPERTY_HINT_NONE, "", ro_flags), "set_region_size", "get_region_size");
}
