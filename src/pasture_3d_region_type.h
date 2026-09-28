// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef PASTURE3D_REGION_TYPE_CLASS_H
#define PASTURE3D_REGION_TYPE_CLASS_H

#include <godot_cpp/classes/resource.hpp>

#include "constants.h"

using namespace godot;

// What kind of region a region is (PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md §C). A C++ Resource, not a
// GDScript one like Pasture3DRoadType, because the texture arrays and the shader need it natively.
//
// A region stores its type's PATH and a cached copy of texel_ratio, so its file still describes itself if
// the type resource moves or changes. When the two ratios disagree the region is flagged
// (Pasture3DData::is_region_type_mismatched) and converted only on an explicit call, never silently.
//
// The built-ins ship at STANDARD_PATH and BACKGROUND_PATH. A region with no type path is Standard: that is
// every region written before types existed.
class Pasture3DRegionType : public Resource {
	GDCLASS(Pasture3DRegionType, Resource);
	CLASS_NAME();

public:
	enum InstancerMode {
		INSTANCER_KEEP,
		INSTANCER_DROP,
	};
	enum MaterialMode {
		MATERIAL_FULL,
		MATERIAL_COLOR_ONLY,
	};

	static inline const char *STANDARD_PATH = "res://addons/pasture_3d/region_types/standard.tres";
	static inline const char *BACKGROUND_PATH = "res://addons/pasture_3d/region_types/background.tres";

	// The smallest map a coarse region may have; region_size / texel_ratio must reach it.
	static constexpr int MIN_MAP_SIZE = 4;
	static bool is_valid_texel_ratio(const int p_ratio) {
		return p_ratio == 1 || p_ratio == 2 || p_ratio == 4 || p_ratio == 8 || p_ratio == 16;
	}

private:
	// Identity
	String _type_name = "Standard";
	Color _editor_color = Color(0.3f, 0.7f, 1.f);
	// Resolution
	int _texel_ratio = 1;
	bool _vertex_collapse = false; // Rendering: phase 3
	// Features
	bool _collision = true;
	InstancerMode _instancer_mode = INSTANCER_KEEP;
	MaterialMode _material_mode = MATERIAL_FULL; // Rendering: phase 3
	bool _sculptable = true;
	bool _paintable = true;
	// Streaming: phase 6
	real_t _load_radius = 1500.f;
	real_t _unload_radius = 1800.f;
	int _priority = 0;

public:
	void set_type_name(const String &p_name);
	String get_type_name() const { return _type_name; }
	void set_editor_color(const Color &p_color);
	Color get_editor_color() const { return _editor_color; }
	void set_texel_ratio(const int p_ratio);
	int get_texel_ratio() const { return _texel_ratio; }
	void set_vertex_collapse(const bool p_enabled);
	bool get_vertex_collapse() const { return _vertex_collapse; }
	void set_collision(const bool p_enabled);
	bool get_collision() const { return _collision; }
	void set_instancer_mode(const InstancerMode p_mode);
	InstancerMode get_instancer_mode() const { return _instancer_mode; }
	void set_material_mode(const MaterialMode p_mode);
	MaterialMode get_material_mode() const { return _material_mode; }
	void set_sculptable(const bool p_enabled);
	bool get_sculptable() const { return _sculptable; }
	void set_paintable(const bool p_enabled);
	bool get_paintable() const { return _paintable; }
	void set_load_radius(const real_t p_radius);
	real_t get_load_radius() const { return _load_radius; }
	void set_unload_radius(const real_t p_radius);
	real_t get_unload_radius() const { return _unload_radius; }
	void set_priority(const int p_priority);
	int get_priority() const { return _priority; }

protected:
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Pasture3DRegionType::InstancerMode);
VARIANT_ENUM_CAST(Pasture3DRegionType::MaterialMode);

#endif // PASTURE3D_REGION_TYPE_CLASS_H
