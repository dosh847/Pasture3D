// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "logger.h"
#include "pasture_3d_layer.h"

/////////////////////
// Private Functions
/////////////////////

Image *Pasture3DLayer::_get_tile_ptr(const Vector2i &p_region_loc, const Vector2i &p_tile_coord) const {
	if (!_tiles.has(p_region_loc)) {
		return nullptr;
	}
	Dictionary region_tiles = _tiles[p_region_loc];
	if (!region_tiles.has(p_tile_coord)) {
		return nullptr;
	}
	return cast_to<Image>(region_tiles[p_tile_coord]);
}

Ref<Image> Pasture3DLayer::_get_or_create_tile(const Vector2i &p_region_loc, const Vector2i &p_tile_coord) {
	Dictionary region_tiles = _tiles.has(p_region_loc) ? Dictionary(_tiles[p_region_loc]) : Dictionary();
	Ref<Image> tile = region_tiles.get(p_tile_coord, Ref<Image>());
	if (tile.is_null()) {
		// New tiles start fully uncovered: value 0, weight 0.
		tile = Util::get_filled_image(V2I(_tile_size), Color(0.f, 0.f, 0.f, 0.f), false, Image::FORMAT_RGF);
		region_tiles[p_tile_coord] = tile;
		_tiles[p_region_loc] = region_tiles;
		_modified = true;
	}
	return tile;
}

/////////////////////
// Public Functions
/////////////////////

void Pasture3DLayer::clear() {
	_name = "Layer";
	_blend = ADD;
	_opacity = 1.f;
	_visible = true;
	_locked = false;
	_reserved = false;
	_owner_id = String();
	_map_type = TYPE_HEIGHT;
	_tile_size = 64;
	_tiles.clear();
	_modified = false;
}

void Pasture3DLayer::set_layer_name(const String &p_name) {
	SET_IF_DIFF(_name, p_name);
	_modified = true;
}

void Pasture3DLayer::set_blend_mode(const BlendMode p_blend) {
	if (p_blend < REPLACE || p_blend > BLEND_MAX) {
		LOG(ERROR, "Invalid blend mode: ", p_blend);
		return;
	}
	SET_IF_DIFF(_blend, p_blend);
	_modified = true;
}

void Pasture3DLayer::set_opacity(const real_t p_opacity) {
	real_t opacity = CLAMP(p_opacity, 0.f, 1.f);
	SET_IF_DIFF(_opacity, opacity);
	_modified = true;
}

void Pasture3DLayer::set_visible(const bool p_visible) {
	SET_IF_DIFF(_visible, p_visible);
	_modified = true;
}

void Pasture3DLayer::set_locked(const bool p_locked) {
	SET_IF_DIFF(_locked, p_locked);
	_modified = true;
}

void Pasture3DLayer::set_reserved(const bool p_reserved) {
	SET_IF_DIFF(_reserved, p_reserved);
	_modified = true;
}

void Pasture3DLayer::set_owner_id(const String &p_owner_id) {
	SET_IF_DIFF(_owner_id, p_owner_id);
	_modified = true;
}

void Pasture3DLayer::set_map_type(const MapType p_map_type) {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Invalid map type: ", p_map_type);
		return;
	}
	if (!_tiles.is_empty() && p_map_type != _map_type) {
		LOG(ERROR, "Cannot change map type after pixel data exists. Clear the layer first.");
		return;
	}
	SET_IF_DIFF(_map_type, p_map_type);
	_modified = true;
}

void Pasture3DLayer::set_tile_size(const int p_tile_size) {
	if (!is_valid_region_size(p_tile_size)) {
		LOG(ERROR, "Invalid tile size: ", p_tile_size, ". Must be power of 2, 64-2048");
		return;
	}
	if (!_tiles.is_empty() && p_tile_size != _tile_size) {
		LOG(ERROR, "Cannot change tile size after pixel data exists. Clear the layer first.");
		return;
	}
	SET_IF_DIFF(_tile_size, p_tile_size);
	_modified = true;
}

void Pasture3DLayer::set_sample(const Vector2i &p_region_loc, const Vector2i &p_px, const real_t p_value, const real_t p_weight) {
	Vector2i tile_coord = _tile_coord(p_px);
	Vector2i local = _tile_local(p_px, tile_coord);
	Ref<Image> tile = _get_or_create_tile(p_region_loc, tile_coord);
	if (tile.is_null()) {
		return;
	}
	// RGF: R = value, G = weight. (Other channels are ignored for FORMAT_RGF.)
	tile->set_pixelv(local, Color(p_value, CLAMP(p_weight, 0.f, 1.f), 0.f, 1.f));
	_modified = true;
}

real_t Pasture3DLayer::get_value(const Vector2i &p_region_loc, const Vector2i &p_px) const {
	Vector2i tile_coord = _tile_coord(p_px);
	Image *tile = _get_tile_ptr(p_region_loc, tile_coord);
	if (!tile) {
		return NAN;
	}
	return tile->get_pixelv(_tile_local(p_px, tile_coord)).r;
}

real_t Pasture3DLayer::get_weight(const Vector2i &p_region_loc, const Vector2i &p_px) const {
	Vector2i tile_coord = _tile_coord(p_px);
	Image *tile = _get_tile_ptr(p_region_loc, tile_coord);
	if (!tile) {
		return 0.f;
	}
	// A dense Base layer aliases a single-channel FORMAT_RF region image and is always covered.
	if (tile->get_format() == Image::FORMAT_RF) {
		return 1.f;
	}
	return tile->get_pixelv(_tile_local(p_px, tile_coord)).g;
}

Ref<Image> Pasture3DLayer::get_tile(const Vector2i &p_region_loc, const Vector2i &p_tile_coord) const {
	if (!_tiles.has(p_region_loc)) {
		return Ref<Image>();
	}
	Dictionary region_tiles = _tiles[p_region_loc];
	return region_tiles.get(p_tile_coord, Ref<Image>());
}

void Pasture3DLayer::set_region_image(const Vector2i &p_region_loc, const Ref<Image> &p_image) {
	if (p_image.is_null()) {
		LOG(ERROR, "Null image for region ", p_region_loc);
		return;
	}
	if (p_image->get_width() != _tile_size || p_image->get_height() != _tile_size) {
		LOG(ERROR, "Image size ", p_image->get_size(), " must match tile size ", _tile_size);
		return;
	}
	Dictionary region_tiles;
	region_tiles[V2I_ZERO] = p_image;
	_tiles[p_region_loc] = region_tiles;
	_modified = true;
}

void Pasture3DLayer::clear_region(const Vector2i &p_region_loc) {
	if (_tiles.erase(p_region_loc)) {
		_modified = true;
	}
}

Rect2i Pasture3DLayer::covered_region_bounds() const {
	Array locations = _tiles.keys();
	if (locations.is_empty()) {
		return Rect2i();
	}
	Vector2i min_loc = locations[0];
	Vector2i max_loc = min_loc;
	for (const Vector2i &loc : locations) {
		min_loc = min_loc.min(loc);
		max_loc = max_loc.max(loc);
	}
	return Rect2i(min_loc, max_loc - min_loc + V2I(1));
}

void Pasture3DLayer::set_data(const Dictionary &p_data) {
#define SET_IF_HAS(var, str) \
	if (p_data.has(str)) { \
		var = p_data[str]; \
	}
	SET_IF_HAS(_name, "name");
	SET_IF_HAS(_opacity, "opacity");
	SET_IF_HAS(_visible, "visible");
	SET_IF_HAS(_locked, "locked");
	SET_IF_HAS(_reserved, "reserved");
	SET_IF_HAS(_owner_id, "owner_id");
	SET_IF_HAS(_tile_size, "tile_size");
	SET_IF_HAS(_tiles, "tiles");
#undef SET_IF_HAS
	if (p_data.has("blend_mode")) {
		_blend = BlendMode(int(p_data["blend_mode"]));
	}
	if (p_data.has("map_type")) {
		_map_type = MapType(int(p_data["map_type"]));
	}
}

Dictionary Pasture3DLayer::get_data() const {
	Dictionary dict;
	dict["name"] = _name;
	dict["blend_mode"] = _blend;
	dict["opacity"] = _opacity;
	dict["visible"] = _visible;
	dict["locked"] = _locked;
	dict["reserved"] = _reserved;
	dict["owner_id"] = _owner_id;
	dict["map_type"] = _map_type;
	dict["tile_size"] = _tile_size;
	dict["tiles"] = _tiles;
	return dict;
}

/////////////////////
// Protected Functions
/////////////////////

void Pasture3DLayer::_bind_methods() {
	BIND_ENUM_CONSTANT(REPLACE);
	BIND_ENUM_CONSTANT(ADD);
	BIND_ENUM_CONSTANT(MAX);
	BIND_ENUM_CONSTANT(MIN);
	BIND_ENUM_CONSTANT(BLEND_MAX);

	ClassDB::bind_method(D_METHOD("clear"), &Pasture3DLayer::clear);

	ClassDB::bind_method(D_METHOD("set_layer_name", "name"), &Pasture3DLayer::set_layer_name);
	ClassDB::bind_method(D_METHOD("get_layer_name"), &Pasture3DLayer::get_layer_name);
	ClassDB::bind_method(D_METHOD("set_blend_mode", "blend_mode"), &Pasture3DLayer::set_blend_mode);
	ClassDB::bind_method(D_METHOD("get_blend_mode"), &Pasture3DLayer::get_blend_mode);
	ClassDB::bind_method(D_METHOD("set_opacity", "opacity"), &Pasture3DLayer::set_opacity);
	ClassDB::bind_method(D_METHOD("get_opacity"), &Pasture3DLayer::get_opacity);
	ClassDB::bind_method(D_METHOD("set_visible", "visible"), &Pasture3DLayer::set_visible);
	ClassDB::bind_method(D_METHOD("is_visible"), &Pasture3DLayer::is_visible);
	ClassDB::bind_method(D_METHOD("set_locked", "locked"), &Pasture3DLayer::set_locked);
	ClassDB::bind_method(D_METHOD("is_locked"), &Pasture3DLayer::is_locked);
	ClassDB::bind_method(D_METHOD("set_reserved", "reserved"), &Pasture3DLayer::set_reserved);
	ClassDB::bind_method(D_METHOD("is_reserved"), &Pasture3DLayer::is_reserved);
	ClassDB::bind_method(D_METHOD("set_owner_id", "owner_id"), &Pasture3DLayer::set_owner_id);
	ClassDB::bind_method(D_METHOD("get_owner_id"), &Pasture3DLayer::get_owner_id);
	ClassDB::bind_method(D_METHOD("set_map_type", "map_type"), &Pasture3DLayer::set_map_type);
	ClassDB::bind_method(D_METHOD("get_map_type"), &Pasture3DLayer::get_map_type);
	ClassDB::bind_method(D_METHOD("set_tile_size", "tile_size"), &Pasture3DLayer::set_tile_size);
	ClassDB::bind_method(D_METHOD("get_tile_size"), &Pasture3DLayer::get_tile_size);

	ClassDB::bind_method(D_METHOD("set_sample", "region_location", "pixel", "value", "weight"), &Pasture3DLayer::set_sample, DEFVAL(1.f));
	ClassDB::bind_method(D_METHOD("get_value", "region_location", "pixel"), &Pasture3DLayer::get_value);
	ClassDB::bind_method(D_METHOD("get_weight", "region_location", "pixel"), &Pasture3DLayer::get_weight);
	ClassDB::bind_method(D_METHOD("get_tile", "region_location", "tile_coord"), &Pasture3DLayer::get_tile);
	ClassDB::bind_method(D_METHOD("set_region_image", "region_location", "image"), &Pasture3DLayer::set_region_image);
	ClassDB::bind_method(D_METHOD("clear_region", "region_location"), &Pasture3DLayer::clear_region);
	ClassDB::bind_method(D_METHOD("has_region", "region_location"), &Pasture3DLayer::has_region);
	ClassDB::bind_method(D_METHOD("get_region_locations"), &Pasture3DLayer::get_region_locations);
	ClassDB::bind_method(D_METHOD("covered_region_bounds"), &Pasture3DLayer::covered_region_bounds);

	ClassDB::bind_method(D_METHOD("set_tiles", "tiles"), &Pasture3DLayer::set_tiles);
	ClassDB::bind_method(D_METHOD("get_tiles"), &Pasture3DLayer::get_tiles);
	ClassDB::bind_method(D_METHOD("set_data", "data"), &Pasture3DLayer::set_data);
	ClassDB::bind_method(D_METHOD("get_data"), &Pasture3DLayer::get_data);

	int meta_flags = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR;
	int ro_flags = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "name", PROPERTY_HINT_NONE, "", meta_flags), "set_layer_name", "get_layer_name");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "blend_mode", PROPERTY_HINT_ENUM, "Replace,Add,Max,Min,BlendMax", meta_flags), "set_blend_mode", "get_blend_mode");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "opacity", PROPERTY_HINT_RANGE, "0.0,1.0,0.01", meta_flags), "set_opacity", "get_opacity");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "visible", PROPERTY_HINT_NONE, "", meta_flags), "set_visible", "is_visible");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "locked", PROPERTY_HINT_NONE, "", meta_flags), "set_locked", "is_locked");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "reserved", PROPERTY_HINT_NONE, "", meta_flags), "set_reserved", "is_reserved");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "owner_id", PROPERTY_HINT_NONE, "", meta_flags), "set_owner_id", "get_owner_id");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "map_type", PROPERTY_HINT_ENUM, "Height,Control,Color", ro_flags), "set_map_type", "get_map_type");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "tile_size", PROPERTY_HINT_NONE, "", ro_flags), "set_tile_size", "get_tile_size");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "tiles", PROPERTY_HINT_NONE, "", ro_flags), "set_tiles", "get_tiles");
}
