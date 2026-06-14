// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef PASTURE3D_EDITOR_CLASS_H
#define PASTURE3D_EDITOR_CLASS_H

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>

#include "pasture_3d.h"
#include "pasture_3d_layer.h"
#include "pasture_3d_region.h"

class Pasture3DEditor : public Object {
	GDCLASS(Pasture3DEditor, Object);
	CLASS_NAME();

public: // Constants
	enum Tool {
		REGION,
		SCULPT,
		HEIGHT,
		TEXTURE,
		COLOR,
		ROUGHNESS,
		AUTOSHADER,
		HOLES,
		NAVIGATION,
		INSTANCER,
		ANGLE, // used for picking, TODO change to a picking tool
		SCALE, // used for picking
		TOOL_MAX,
	};

	static inline const char *TOOLNAME[] = {
		"Region",
		"Sculpt",
		"Height",
		"Texture",
		"Color",
		"Roughness",
		"Auto Shader",
		"Holes",
		"Navigation",
		"Instancer",
		"Angle",
		"Scale",
		"TOOL_MAX",
	};

	enum Operation {
		ADD,
		SUBTRACT,
		REPLACE,
		AVERAGE,
		GRADIENT,
		OP_MAX,
	};

	static inline const char *OPNAME[] = {
		"Add",
		"Subtract",
		"Replace",
		"Average",
		"Gradient",
		"OP_MAX",
	};

	enum AverageMode {
		AVG_HEIGHT,
		AVG_BLEND,
		AVG_ROUGHNESS,
	};

private:
	Pasture3D *_terrain = nullptr;

	// Painter settings & variables
	Tool _tool = REGION;
	Operation _operation = ADD;
	Dictionary _brush_data;
	Vector3 _operation_position = V3_ZERO;
	Vector3 _operation_movement = V3_ZERO;
	Array _operation_movement_history;
	bool _is_operating = false;
	uint64_t _last_region_bounds_error = 0;
	TypedArray<Pasture3DRegion> _original_regions; // Queue for undo
	TypedArray<Pasture3DRegion> _edited_regions; // Queue for redo
	TypedArray<Vector2i> _added_removed_locations; // Queue for added/removed locations
	AABB _modified_area;
	Dictionary _undo_data; // See _get_undo_data for definition
	uint64_t _last_pen_tick = 0;

	// Non-destructive layer routing (PASTURE3D_LAYERS_GUIDE.md §6). When a stroke targets a height
	// layer, writes go into _stroke_layer (the active layer) and the touched region rects are
	// recomposited, instead of writing the region image directly. Null _stroke_layer => legacy path.
	Ref<Pasture3DLayer> _stroke_layer; // Active height layer captured for the current stroke
	bool _stroke_blocked = false; // Active layer is locked/reserved; swallow the stroke
	Dictionary _layer_undo_tiles; // region_loc -> deep tile snapshot taken before the stroke
	Dictionary _layer_redo_tiles; // region_loc -> deep tile snapshot taken after the stroke
	Dictionary _stroke_dirty; // region_loc -> Rect2i of region-local pixels this stroke touched

	void _send_region_aabb(const Vector2i &p_region_loc, const Vector2 &p_height_range = V2_ZERO);
	Ref<Pasture3DRegion> _operate_region(const Vector2i &p_region_loc);
	void _operate_map(const Vector3 &p_global_position, const real_t p_camera_direction);
	// Snapshot the active layer's tiles for a region once, before the stroke first modifies them.
	void _backup_layer_tile(const Vector2i &p_region_loc);
	// Best-effort UE-style warning flash when a stroke hits a locked/reserved active layer.
	void _notify_layer_blocked(const Ref<Pasture3DLayer> &p_layer) const;
	MapType _get_map_type() const;
	bool _is_in_bounds(const Point2i &p_pixel, const Point2i &p_size) const;
	Vector2 _get_uv_position(const Vector3 &p_global_position, const int p_region_size, const real_t p_vertex_spacing) const;
	Vector2 _get_rotated_uv(const Vector2 &p_uv, const real_t p_angle) const;
	void _store_undo();
	void _apply_undo(const Dictionary &p_data);
	float _average(const AverageMode p_mode, const Vector3 &p_global_position, const float p_base, const float p_nan_val = 0.f, bool p_alt = false) const;
	Color _average(const Vector3 &p_global_position, const Color &p_base) const;

public:
	Pasture3DEditor() {}
	~Pasture3DEditor() {}

	void set_terrain(Pasture3D *p_terrain) { _terrain = p_terrain; }
	Pasture3D *get_terrain() const { return _terrain; }

	void set_brush_data(const Dictionary &p_data);
	Dictionary get_brush_data() const { return _brush_data; }
	void set_tool(const Tool p_tool);
	Tool get_tool() const { return _tool; }
	void set_operation(const Operation p_operation);
	Operation get_operation() const { return _operation; }

	void start_operation(const Vector3 &p_global_position);
	bool is_operating() const { return _is_operating; }
	void operate(const Vector3 &p_global_position, const real_t p_camera_direction);
	void backup_region(const Ref<Pasture3DRegion> &p_region);
	void stop_operation();

protected:
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Pasture3DEditor::Operation);
VARIANT_ENUM_CAST(Pasture3DEditor::Tool);

// Inline functions

inline MapType Pasture3DEditor::_get_map_type() const {
	switch (_tool) {
		case SCULPT:
		case HEIGHT:
		case INSTANCER:
			return TYPE_HEIGHT;
			break;
		case TEXTURE:
		case AUTOSHADER:
		case HOLES:
		case NAVIGATION:
		case ANGLE:
		case SCALE:
			return TYPE_CONTROL;
			break;
		case COLOR:
		case ROUGHNESS:
			return TYPE_COLOR;
			break;
		default:
			return TYPE_MAX;
	}
}

inline bool Pasture3DEditor::_is_in_bounds(const Point2i &p_pixel, const Point2i &p_size) const {
	bool positive = p_pixel.x >= 0 && p_pixel.y >= 0;
	bool less_than_max = p_pixel.x < p_size.x && p_pixel.y < p_size.y;
	return positive && less_than_max;
}

inline Vector2 Pasture3DEditor::_get_uv_position(const Vector3 &p_global_position, const int p_region_size, const real_t p_vertex_spacing) const {
	Vector2 descaled_position_2d = Vector2(p_global_position.x, p_global_position.z) / p_vertex_spacing;
	Vector2 region_position = descaled_position_2d / real_t(p_region_size);
	region_position = region_position.floor();
	Vector2 uv_position = (descaled_position_2d / real_t(p_region_size)) - region_position;
	return uv_position;
}

inline Vector2 Pasture3DEditor::_get_rotated_uv(const Vector2 &p_uv, const real_t p_angle) const {
	Vector2 rotation_offset = V2(0.5f);
	Vector2 uv = (p_uv - rotation_offset).rotated(p_angle) + rotation_offset;
	return uv.clamp(V2_ZERO, V2(1.f));
}

#endif // PASTURE3D_EDITOR_CLASS_H
