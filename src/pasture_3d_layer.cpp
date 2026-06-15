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

// Overlay tile format follows the map type: color overlays carry RGBA8 (rgb albedo, a = weight),
// height/control overlays carry RGF (r = value/control-bits, g = weight). Base tiles are assigned
// directly via set_region_image and may be any region-map format (RF / RGBA8).
Image::Format Pasture3DLayer::_overlay_format() const {
	return _map_type == TYPE_COLOR ? Image::FORMAT_RGBA8 : Image::FORMAT_RGF;
}

Ref<Image> Pasture3DLayer::_get_or_create_tile(const Vector2i &p_region_loc, const Vector2i &p_tile_coord) {
	Dictionary region_tiles = _tiles.has(p_region_loc) ? Dictionary(_tiles[p_region_loc]) : Dictionary();
	Ref<Image> tile = region_tiles.get(p_tile_coord, Ref<Image>());
	if (tile.is_null()) {
		// New tiles start fully uncovered: all channels 0 (value 0, weight 0).
		tile = Util::get_filled_image(V2I(_tile_size), Color(0.f, 0.f, 0.f, 0.f), false, _overlay_format());
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
	_is_base = false;
	_tiles.clear();
	_modified = false;
}

void Pasture3DLayer::set_base(const bool p_is_base) {
	SET_IF_DIFF(_is_base, p_is_base);
	_modified = true;
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

void Pasture3DLayer::set_sample_color(const Vector2i &p_region_loc, const Vector2i &p_px, const Color &p_color, const real_t p_weight) {
	Vector2i tile_coord = _tile_coord(p_px);
	Vector2i local = _tile_local(p_px, tile_coord);
	Ref<Image> tile = _get_or_create_tile(p_region_loc, tile_coord);
	if (tile.is_null()) {
		return;
	}
	// RGBA8 color overlay: RGB = albedo, A = coverage weight.
	tile->set_pixelv(local, Color(p_color.r, p_color.g, p_color.b, CLAMP(p_weight, 0.f, 1.f)));
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

Color Pasture3DLayer::get_sample(const Vector2i &p_region_loc, const Vector2i &p_px) const {
	Vector2i tile_coord = _tile_coord(p_px);
	Image *tile = _get_tile_ptr(p_region_loc, tile_coord);
	if (!tile) {
		return Color(0.f, 0.f, 0.f, 0.f);
	}
	return tile->get_pixelv(_tile_local(p_px, tile_coord));
}

real_t Pasture3DLayer::get_weight(const Vector2i &p_region_loc, const Vector2i &p_px) const {
	Vector2i tile_coord = _tile_coord(p_px);
	Image *tile = _get_tile_ptr(p_region_loc, tile_coord);
	if (!tile) {
		return 0.f;
	}
	// A dense Base is always covered: its alpha/green may carry data (roughness for a color base), not
	// coverage. Single-channel FORMAT_RF bases (height/control) are likewise always covered.
	if (_is_base || tile->get_format() == Image::FORMAT_RF) {
		return 1.f;
	}
	// Color overlays carry coverage in the alpha channel; height/control overlays carry it in green.
	if (tile->get_format() == Image::FORMAT_RGBA8) {
		return tile->get_pixelv(_tile_local(p_px, tile_coord)).a;
	}
	return tile->get_pixelv(_tile_local(p_px, tile_coord)).g;
}

// Deep-copies an image's pixel data so a snapshot never aliases the live tile.
static Ref<Image> _dup_image(const Ref<Image> &p_img) {
	if (p_img.is_null()) {
		return Ref<Image>();
	}
	return Image::create_from_data(p_img->get_width(), p_img->get_height(), p_img->has_mipmaps(), p_img->get_format(), p_img->get_data());
}

Dictionary Pasture3DLayer::duplicate_region_tiles(const Vector2i &p_region_loc) const {
	Dictionary out;
	if (!_tiles.has(p_region_loc)) {
		return out;
	}
	Dictionary region_tiles = _tiles[p_region_loc];
	Array coords = region_tiles.keys();
	for (const Vector2i &coord : coords) {
		Ref<Image> img = region_tiles[coord];
		out[coord] = _dup_image(img);
	}
	return out;
}

void Pasture3DLayer::restore_region_tiles(const Vector2i &p_region_loc, const Dictionary &p_tiles) {
	if (p_tiles.is_empty()) {
		_tiles.erase(p_region_loc);
	} else {
		// Store a fresh deep copy so later mutation of the snapshot can't bleed into our tiles.
		Dictionary region_tiles;
		Array coords = p_tiles.keys();
		for (const Vector2i &coord : coords) {
			Ref<Image> img = p_tiles[coord];
			region_tiles[coord] = _dup_image(img);
		}
		_tiles[p_region_loc] = region_tiles;
	}
	_modified = true;
}

Dictionary Pasture3DLayer::clone_tile_snapshot(const Dictionary &p_snapshot) {
	Dictionary out;
	Array locs = p_snapshot.keys();
	for (const Vector2i &loc : locs) {
		Dictionary region_tiles = p_snapshot[loc];
		Dictionary cloned;
		Array coords = region_tiles.keys();
		for (const Vector2i &coord : coords) {
			Ref<Image> img = region_tiles[coord];
			cloned[coord] = _dup_image(img);
		}
		out[loc] = cloned;
	}
	return out;
}

Ref<Pasture3DLayer> Pasture3DLayer::clone() const {
	Ref<Pasture3DLayer> c;
	c.instantiate();
	Dictionary d = get_data();
	d.erase("tiles"); // Copy pixels separately as deep duplicates.
	c->set_data(d);
	Array locations = _tiles.keys();
	for (const Vector2i &loc : locations) {
		c->restore_region_tiles(loc, duplicate_region_tiles(loc));
	}
	return c;
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

bool Pasture3DLayer::clear_tiles_in_rect(const Vector2i &p_region_loc, const Rect2i &p_px_rect) {
	if (!_tiles.has(p_region_loc) || !p_px_rect.has_area()) {
		return false;
	}
	Dictionary region_tiles = _tiles[p_region_loc];
	Array coords = region_tiles.keys();
	bool any = false;
	for (const Vector2i &coord : coords) {
		// A tile covers vertices [coord*tile_size, coord*tile_size + tile_size).
		Rect2i tile_rect(coord * _tile_size, V2I(_tile_size));
		if (tile_rect.intersects(p_px_rect)) {
			region_tiles.erase(coord);
			any = true;
		}
	}
	if (any) {
		if (region_tiles.is_empty()) {
			_tiles.erase(p_region_loc);
		} else {
			_tiles[p_region_loc] = region_tiles;
		}
		_modified = true;
	}
	return any;
}

bool Pasture3DLayer::_tile_all_uncovered(const Ref<Image> &p_tile) {
	if (p_tile.is_null()) {
		return true;
	}
	// A dense single-channel FORMAT_RF base (height/control) is always covered (never empty).
	if (p_tile->get_format() == Image::FORMAT_RF) {
		return false;
	}
	// Coverage lives in alpha for RGBA8 (color overlays), green for RGF (height/control overlays).
	const bool rgba = p_tile->get_format() == Image::FORMAT_RGBA8;
	const int w = p_tile->get_width();
	const int h = p_tile->get_height();
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			const Color c = p_tile->get_pixel(x, y);
			if ((rgba ? c.a : c.g) != 0.f) {
				return false; // Some pixel is owned by this layer.
			}
		}
	}
	return true;
}

bool Pasture3DLayer::gc_region(const Vector2i &p_region_loc) {
	if (_is_base) {
		return !_tiles.has(p_region_loc); // A base is full-coverage; never GC its tiles.
	}
	if (!_tiles.has(p_region_loc)) {
		return true; // Already absent == effectively empty.
	}
	Dictionary region_tiles = _tiles[p_region_loc];
	Array coords = region_tiles.keys();
	for (const Vector2i &coord : coords) {
		Ref<Image> tile = region_tiles[coord];
		if (_tile_all_uncovered(tile)) {
			region_tiles.erase(coord);
			_modified = true;
		}
	}
	if (region_tiles.is_empty()) {
		_tiles.erase(p_region_loc);
		_modified = true;
		return true;
	}
	_tiles[p_region_loc] = region_tiles;
	return false;
}

void Pasture3DLayer::gc() {
	Array locations = _tiles.keys();
	for (const Vector2i &loc : locations) {
		gc_region(loc);
	}
}

int Pasture3DLayer::get_region_tile_count(const Vector2i &p_region_loc) const {
	if (!_tiles.has(p_region_loc)) {
		return 0;
	}
	return Dictionary(_tiles[p_region_loc]).size();
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
	SET_IF_HAS(_is_base, "is_base");
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
	dict["is_base"] = _is_base;
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
	ClassDB::bind_method(D_METHOD("set_base", "is_base"), &Pasture3DLayer::set_base);
	ClassDB::bind_method(D_METHOD("is_base"), &Pasture3DLayer::is_base);

	ClassDB::bind_method(D_METHOD("set_sample", "region_location", "pixel", "value", "weight"), &Pasture3DLayer::set_sample, DEFVAL(1.f));
	ClassDB::bind_method(D_METHOD("set_sample_color", "region_location", "pixel", "color", "weight"), &Pasture3DLayer::set_sample_color, DEFVAL(1.f));
	ClassDB::bind_method(D_METHOD("get_value", "region_location", "pixel"), &Pasture3DLayer::get_value);
	ClassDB::bind_method(D_METHOD("get_sample", "region_location", "pixel"), &Pasture3DLayer::get_sample);
	ClassDB::bind_method(D_METHOD("get_weight", "region_location", "pixel"), &Pasture3DLayer::get_weight);
	ClassDB::bind_method(D_METHOD("get_tile", "region_location", "tile_coord"), &Pasture3DLayer::get_tile);
	ClassDB::bind_method(D_METHOD("set_region_image", "region_location", "image"), &Pasture3DLayer::set_region_image);
	ClassDB::bind_method(D_METHOD("clear_region", "region_location"), &Pasture3DLayer::clear_region);
	ClassDB::bind_method(D_METHOD("clear_tiles_in_rect", "region_location", "pixel_rect"), &Pasture3DLayer::clear_tiles_in_rect);
	ClassDB::bind_method(D_METHOD("gc_region", "region_location"), &Pasture3DLayer::gc_region);
	ClassDB::bind_method(D_METHOD("gc"), &Pasture3DLayer::gc);
	ClassDB::bind_method(D_METHOD("has_region", "region_location"), &Pasture3DLayer::has_region);
	ClassDB::bind_method(D_METHOD("get_region_tile_count", "region_location"), &Pasture3DLayer::get_region_tile_count);
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
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "is_base", PROPERTY_HINT_NONE, "", ro_flags), "set_base", "is_base");
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "tiles", PROPERTY_HINT_NONE, "", ro_flags), "set_tiles", "get_tiles");
}
