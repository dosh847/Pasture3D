// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(
//INSERT: REGION_MAP
// The region map: an RF texture, one texel per region location, offset by _region_map_size / 2. Each texel
// holds an exact small integer: 0 = no region, otherwise slot + 1 (Pasture3DData::region_map_encode, the
// only other place this encoding is defined). The slot indexes the texture arrays and _region_locations.
uniform highp sampler2D _region_map : filter_nearest, repeat_disable;
uniform int _region_map_size = 256;

// Slot of the region at map position `pos` (location + _region_map_size / 2), or -1 if none.
int region_map_slot(ivec2 pos) {
	if (uint(pos.x | pos.y) >= uint(_region_map_size)) {
		return -1;
	}
	int slot = int(texelFetch(_region_map, pos, 0).r + 0.5) - 1;
	return (slot >= 0 && slot < MAX_REGIONS) ? slot : -1;
}

)"
