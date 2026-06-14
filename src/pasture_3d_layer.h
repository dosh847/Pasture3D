// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef PASTURE3D_LAYER_CLASS_H
#define PASTURE3D_LAYER_CLASS_H

#include <godot_cpp/classes/image.hpp>

#include "constants.h"
#include "pasture_3d_region.h" // MapType, FORMAT[]
#include "pasture_3d_util.h"

// A single non-destructive height-map layer.
//
// Pixel data is stored as a sparse, two-level map: region_location -> (tile_coord -> Image).
// The outer key reuses the engine's region grid so coordinate math lines up with Pasture3DData.
// The inner key is a sub-region tile of `_tile_size` vertices. Phase 1 ships with
// `_tile_size == region_size` (one tile per region); sub-tiling is a later, drop-in optimization.
//
// Each sample is a (value, weight) pair. Tiles are stored as FORMAT_RGF (R = value, G = weight).
// A weight of 0 means the pixel is not owned by this layer and is skipped when compositing.
// The dense Base layer may instead alias a region's plain FORMAT_RF height map (always covered,
// weight implicitly 1) to avoid doubling memory; sampling handles both formats transparently.
//
// This class is editor-only authoring data. Compositing the stack down into the runtime region
// images happens in Pasture3DData (phase 2); v1 ships height layers only (TYPE_HEIGHT).
class Pasture3DLayer : public Resource {
	GDCLASS(Pasture3DLayer, Resource);
	CLASS_NAME();

public: // Constants
	enum BlendMode {
		REPLACE, // result = lerp(below, value, weight*opacity)  (absolute authoring / Base)
		ADD, // result = below + value * weight * opacity         (signed deltas; detail)
		MAX, // result = max(below, lerp(below, value, w*op))     (stamp hills, raise-only)
		MIN, // result = min(below, lerp(below, value, w*op))     (carve, lower-only)
		BLEND_MAX, // size marker; reserved for a future blend mode
	};

private:
	// Saved metadata
	String _name = "Layer";
	BlendMode _blend = ADD;
	real_t _opacity = 1.f;
	bool _visible = true;
	bool _locked = false;
	bool _reserved = false; // Owned by a tool/node; user edits disabled
	String _owner_id; // Optional: node path / generator id that owns it
	MapType _map_type = TYPE_HEIGHT; // v1: height only
	int _tile_size = 64; // Sub-region tile edge in vertices (power of two, <= region_size)

	// Saved pixel data. Sparse, sub-region tiles.
	//   _tiles[region_location:Vector2i] -> Dict[tile_coord:Vector2i] -> Ref<Image>(FORMAT_RGF)
	Dictionary _tiles;

	// Working data, not saved
	bool _modified = false;

	// Helpers
	Vector2i _tile_coord(const Vector2i &p_px) const { return V2I_DIVIDE_FLOOR(p_px, _tile_size); }
	Vector2i _tile_local(const Vector2i &p_px, const Vector2i &p_tile_coord) const { return p_px - p_tile_coord * _tile_size; }
	Image *_get_tile_ptr(const Vector2i &p_region_loc, const Vector2i &p_tile_coord) const;
	Ref<Image> _get_or_create_tile(const Vector2i &p_region_loc, const Vector2i &p_tile_coord);

public:
	Pasture3DLayer() {}
	~Pasture3DLayer() {}

	void clear();

	// Metadata
	void set_layer_name(const String &p_name);
	String get_layer_name() const { return _name; }
	void set_blend_mode(const BlendMode p_blend);
	BlendMode get_blend_mode() const { return _blend; }
	void set_opacity(const real_t p_opacity);
	real_t get_opacity() const { return _opacity; }
	void set_visible(const bool p_visible);
	bool is_visible() const { return _visible; }
	void set_locked(const bool p_locked);
	bool is_locked() const { return _locked; }
	void set_reserved(const bool p_reserved);
	bool is_reserved() const { return _reserved; }
	void set_owner_id(const String &p_owner_id);
	String get_owner_id() const { return _owner_id; }
	void set_map_type(const MapType p_map_type);
	MapType get_map_type() const { return _map_type; }
	void set_tile_size(const int p_tile_size);
	int get_tile_size() const { return _tile_size; }

	// Pixel access. p_px is a vertex offset within the region [0, region_size).
	void set_sample(const Vector2i &p_region_loc, const Vector2i &p_px, const real_t p_value, const real_t p_weight = 1.f);
	real_t get_value(const Vector2i &p_region_loc, const Vector2i &p_px) const; // NAN if uncovered
	real_t get_weight(const Vector2i &p_region_loc, const Vector2i &p_px) const; // 0 if uncovered

	// Tile / region access.
	Ref<Image> get_tile(const Vector2i &p_region_loc, const Vector2i &p_tile_coord) const;
	// Adopt a whole region image as this layer's single tile. Only valid when _tile_size == region
	// size (the Phase 1 default); used to alias the Base layer onto existing region height maps.
	void set_region_image(const Vector2i &p_region_loc, const Ref<Image> &p_image);
	void clear_region(const Vector2i &p_region_loc); // Used by tools to re-render
	bool has_region(const Vector2i &p_region_loc) const { return _tiles.has(p_region_loc); }
	TypedArray<Vector2i> get_region_locations() const { return _tiles.keys(); }
	Rect2i covered_region_bounds() const;

	// Working flags
	void set_modified(const bool p_modified) { _modified = p_modified; }
	bool is_modified() const { return _modified; }

	// Serialization
	void set_tiles(const Dictionary &p_tiles) { _tiles = p_tiles; }
	Dictionary get_tiles() const { return _tiles; }
	void set_data(const Dictionary &p_data);
	Dictionary get_data() const;

protected:
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Pasture3DLayer::BlendMode);

#endif // PASTURE3D_LAYER_CLASS_H
