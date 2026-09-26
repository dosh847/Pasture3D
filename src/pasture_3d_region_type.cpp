// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "logger.h"
#include "pasture_3d_region_type.h"

// Every setter emits changed, so an edit to a live type reaches whoever listens.
#define TYPE_SET(m_member, m_value) \
	if (m_member == m_value) {      \
		return;                     \
	}                               \
	m_member = m_value;             \
	emit_changed();

void Pasture3DRegionType::set_type_name(const String &p_name) { TYPE_SET(_type_name, p_name); }
void Pasture3DRegionType::set_editor_color(const Color &p_color) { TYPE_SET(_editor_color, p_color); }

void Pasture3DRegionType::set_texel_ratio(const int p_ratio) {
	if (!is_valid_texel_ratio(p_ratio)) {
		LOG(ERROR, "Invalid texel ratio: ", p_ratio, ". Must be 1, 2, 4, 8 or 16");
		return;
	}
	TYPE_SET(_texel_ratio, p_ratio);
}

void Pasture3DRegionType::set_vertex_collapse(const bool p_enabled) { TYPE_SET(_vertex_collapse, p_enabled); }
void Pasture3DRegionType::set_collision(const bool p_enabled) { TYPE_SET(_collision, p_enabled); }
void Pasture3DRegionType::set_instancer_mode(const InstancerMode p_mode) { TYPE_SET(_instancer_mode, p_mode); }
void Pasture3DRegionType::set_material_mode(const MaterialMode p_mode) { TYPE_SET(_material_mode, p_mode); }
void Pasture3DRegionType::set_sculptable(const bool p_enabled) { TYPE_SET(_sculptable, p_enabled); }
void Pasture3DRegionType::set_paintable(const bool p_enabled) { TYPE_SET(_paintable, p_enabled); }
void Pasture3DRegionType::set_load_radius(const real_t p_radius) { TYPE_SET(_load_radius, MAX(p_radius, real_t(0.f))); }
void Pasture3DRegionType::set_unload_radius(const real_t p_radius) { TYPE_SET(_unload_radius, MAX(p_radius, real_t(0.f))); }
void Pasture3DRegionType::set_priority(const int p_priority) { TYPE_SET(_priority, p_priority); }

#undef TYPE_SET

void Pasture3DRegionType::_bind_methods() {
	BIND_ENUM_CONSTANT(INSTANCER_KEEP);
	BIND_ENUM_CONSTANT(INSTANCER_DROP);
	BIND_ENUM_CONSTANT(MATERIAL_FULL);
	BIND_ENUM_CONSTANT(MATERIAL_COLOR_ONLY);

	ClassDB::bind_static_method("Pasture3DRegionType", D_METHOD("is_valid_texel_ratio", "ratio"), &Pasture3DRegionType::is_valid_texel_ratio);

	ClassDB::bind_method(D_METHOD("set_type_name", "name"), &Pasture3DRegionType::set_type_name);
	ClassDB::bind_method(D_METHOD("get_type_name"), &Pasture3DRegionType::get_type_name);
	ClassDB::bind_method(D_METHOD("set_editor_color", "color"), &Pasture3DRegionType::set_editor_color);
	ClassDB::bind_method(D_METHOD("get_editor_color"), &Pasture3DRegionType::get_editor_color);
	ClassDB::bind_method(D_METHOD("set_texel_ratio", "ratio"), &Pasture3DRegionType::set_texel_ratio);
	ClassDB::bind_method(D_METHOD("get_texel_ratio"), &Pasture3DRegionType::get_texel_ratio);
	ClassDB::bind_method(D_METHOD("set_vertex_collapse", "enabled"), &Pasture3DRegionType::set_vertex_collapse);
	ClassDB::bind_method(D_METHOD("get_vertex_collapse"), &Pasture3DRegionType::get_vertex_collapse);
	ClassDB::bind_method(D_METHOD("set_collision", "enabled"), &Pasture3DRegionType::set_collision);
	ClassDB::bind_method(D_METHOD("get_collision"), &Pasture3DRegionType::get_collision);
	ClassDB::bind_method(D_METHOD("set_instancer_mode", "mode"), &Pasture3DRegionType::set_instancer_mode);
	ClassDB::bind_method(D_METHOD("get_instancer_mode"), &Pasture3DRegionType::get_instancer_mode);
	ClassDB::bind_method(D_METHOD("set_material_mode", "mode"), &Pasture3DRegionType::set_material_mode);
	ClassDB::bind_method(D_METHOD("get_material_mode"), &Pasture3DRegionType::get_material_mode);
	ClassDB::bind_method(D_METHOD("set_sculptable", "enabled"), &Pasture3DRegionType::set_sculptable);
	ClassDB::bind_method(D_METHOD("get_sculptable"), &Pasture3DRegionType::get_sculptable);
	ClassDB::bind_method(D_METHOD("set_paintable", "enabled"), &Pasture3DRegionType::set_paintable);
	ClassDB::bind_method(D_METHOD("get_paintable"), &Pasture3DRegionType::get_paintable);
	ClassDB::bind_method(D_METHOD("set_load_radius", "radius"), &Pasture3DRegionType::set_load_radius);
	ClassDB::bind_method(D_METHOD("get_load_radius"), &Pasture3DRegionType::get_load_radius);
	ClassDB::bind_method(D_METHOD("set_unload_radius", "radius"), &Pasture3DRegionType::set_unload_radius);
	ClassDB::bind_method(D_METHOD("get_unload_radius"), &Pasture3DRegionType::get_unload_radius);
	ClassDB::bind_method(D_METHOD("set_priority", "priority"), &Pasture3DRegionType::set_priority);
	ClassDB::bind_method(D_METHOD("get_priority"), &Pasture3DRegionType::get_priority);

	ADD_GROUP("Identity", "");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "type_name"), "set_type_name", "get_type_name");
	ADD_PROPERTY(PropertyInfo(Variant::COLOR, "editor_color"), "set_editor_color", "get_editor_color");
	ADD_GROUP("Resolution", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "texel_ratio", PROPERTY_HINT_ENUM, "1:1,2:2,4:4,8:8,16:16"), "set_texel_ratio", "get_texel_ratio");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "vertex_collapse"), "set_vertex_collapse", "get_vertex_collapse");
	ADD_GROUP("Features", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "collision"), "set_collision", "get_collision");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "instancer_mode", PROPERTY_HINT_ENUM, "Keep,Drop"), "set_instancer_mode", "get_instancer_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "material_mode", PROPERTY_HINT_ENUM, "Full,Color Only"), "set_material_mode", "get_material_mode");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "sculptable"), "set_sculptable", "get_sculptable");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "paintable"), "set_paintable", "get_paintable");
	ADD_GROUP("Streaming", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "load_radius", PROPERTY_HINT_RANGE, "0,100000,1,or_greater,suffix:m"), "set_load_radius", "get_load_radius");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "unload_radius", PROPERTY_HINT_RANGE, "0,100000,1,or_greater,suffix:m"), "set_unload_radius", "get_unload_radius");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "priority"), "set_priority", "get_priority");
}
