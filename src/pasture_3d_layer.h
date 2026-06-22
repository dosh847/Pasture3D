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
// The tile format follows the layer's map type (Phase 7):
//   TYPE_HEIGHT / TYPE_CONTROL overlay tiles: FORMAT_RGF — R = value (height, or control uint32 as
//     float bits), G = weight in [0,1]. A weight of 0 means the pixel is not owned by this layer.
//   TYPE_COLOR overlay tiles: FORMAT_RGBA8 — RGB = albedo, A = coverage weight (roughness is carried
//     by the region color map's base, not authored per color layer).
// The dense Base of each map type may instead alias / own a region map verbatim: the height Base is a
// FORMAT_RF region image (always covered, weight implicitly 1); the control Base is FORMAT_RF; the
// color Base is FORMAT_RGBA8 with `_is_base` set (so its alpha reads as roughness, not weight). Sampling
// (get_value / get_sample / get_weight) handles all formats transparently.
//
// This class is editor-only authoring data. Compositing the stack down into the runtime region images
// happens in Pasture3DData: height blends (REPLACE/ADD/MAX/MIN), control is topmost-covered-wins (no
// arithmetic blend), and color is alpha-over by weight (PASTURE3D_LAYERS_GUIDE.md §5.1).
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
	MapType _map_type = TYPE_HEIGHT; // height (RGF value+weight), control (RGF bits+weight), color (RGBA8 rgb+weight-alpha)
	int _tile_size = 64; // Sub-region tile edge in vertices (power of two, <= region_size)
	// Dense, always-covered base of its map type (Phase 7). The bottom of each map type's sub-stack:
	// height Base aliases/owns the region height map; control/color bases own a deep copy of the region
	// control/color map so compositing has a hand-authored source distinct from the composite target
	// (the idempotency requirement, PASTURE3D_LAYERS_GUIDE.md §5.1). A base is full-coverage (weight 1)
	// and is never garbage-collected.
	bool _is_base = false;

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
	Image::Format _overlay_format() const; // RGBA8 for color, RGF for height/control overlays
	// True if every sample in a tile is uncovered (weight 0). An aliased Base FORMAT_RF tile is always
	// covered, so it is never considered empty (the Base must never be GC'd — §5.1 / §10.4).
	static bool _tile_all_uncovered(const Ref<Image> &p_tile);

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
	void set_base(const bool p_is_base);
	bool is_base() const { return _is_base; }

	// Pixel access. p_px is a vertex offset within the region [0, region_size).
	// set_sample writes a scalar value + weight (height / control overlays, FORMAT_RGF tiles).
	void set_sample(const Vector2i &p_region_loc, const Vector2i &p_px, const real_t p_value, const real_t p_weight = 1.f);
	// set_sample_color writes an RGBA color + weight (color overlays, FORMAT_RGBA8 tiles; weight -> alpha).
	void set_sample_color(const Vector2i &p_region_loc, const Vector2i &p_px, const Color &p_color, const real_t p_weight = 1.f);
	real_t get_value(const Vector2i &p_region_loc, const Vector2i &p_px) const; // NAN if uncovered; .r of the tile
	// Full RGBA of the tile pixel (color compositing). Color(0,0,0,0) if no tile exists.
	Color get_sample(const Vector2i &p_region_loc, const Vector2i &p_px) const;
	real_t get_weight(const Vector2i &p_region_loc, const Vector2i &p_px) const; // 0 if uncovered

	// Deep snapshot/restore of one region's tiles (images duplicated), for undo and duplication.
	// duplicate_region_tiles returns an empty Dictionary if the region is absent; restore with an
	// empty Dictionary erases the region (i.e. restores the "uncovered" pre-stroke state).
	Dictionary duplicate_region_tiles(const Vector2i &p_region_loc) const;
	void restore_region_tiles(const Vector2i &p_region_loc, const Dictionary &p_tiles);
	// Deep-clone a whole region_loc -> {tile_coord -> Image} snapshot (every Image duplicated) into a
	// dictionary that shares nothing with the input. The editor uses this so a committed undo/redo
	// payload owns its tile data and can't be emptied when the live snapshot members are cleared.
	static Dictionary clone_tile_snapshot(const Dictionary &p_snapshot);
	// A deep copy of the whole layer (metadata + duplicated tiles), used by "Duplicate layer".
	Ref<Pasture3DLayer> clone() const;

	// Tile / region access.
	Ref<Image> get_tile(const Vector2i &p_region_loc, const Vector2i &p_tile_coord) const;
	// Public wrapper over _get_or_create_tile for the batched raw-tile stamp apply (brush_raster).
	// Returns the overlay tile (created uncovered if absent); caller resolves it once per tile-block and
	// reads/writes its raw bytes directly (the Round-3 idiom), instead of per-cell set_sample.
	Ref<Image> get_or_create_tile(const Vector2i &p_region_loc, const Vector2i &p_tile_coord) { return _get_or_create_tile(p_region_loc, p_tile_coord); }
	// Adopt a whole region image as this layer's single tile. Only valid when _tile_size == region
	// size (the Phase 1 default); used to alias the Base layer onto existing region height maps.
	void set_region_image(const Vector2i &p_region_loc, const Ref<Image> &p_image);
	void clear_region(const Vector2i &p_region_loc); // Used by tools to re-render
	// Sub-tile-precise clear: drop only the sub-tiles overlapping p_px_rect (a region-local vertex
	// rect), and drop the region entry if it becomes empty. Returns true if any tile was removed.
	// This scopes a tool re-render to its own footprint instead of wiping the whole region (the
	// Phase 5 partial-refresh fix); falls back to clearing the one tile when _tile_size == region size.
	bool clear_tiles_in_rect(const Vector2i &p_region_loc, const Rect2i &p_px_rect);
	// Tile garbage-collection: free tiles that became fully uncovered (every weight 0), and drop the
	// region entry when its last tile goes, so erasing/moving a feature actually reclaims memory.
	// gc_region returns true if the region entry is now gone (was/became empty). gc sweeps all regions.
	bool gc_region(const Vector2i &p_region_loc);
	void gc();
	bool has_region(const Vector2i &p_region_loc) const { return _tiles.has(p_region_loc); }
	int get_region_tile_count(const Vector2i &p_region_loc) const; // Allocated sub-tiles in a region
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
