// Pasture3D Water -- the ocean's open-water shading, for WaterReferenceABGate (PASTURE3D_WATER_REFERENCE_SPEC.md
// R6). water_ocean.gdshader's lit path less what only acts near land or needs its node: no clipmap, terrain
// check, depth fade or shore foam (§3.4, D4). Over open water each of those is a no-op -- the depth fade's
// absorption is total and its alpha 1 -- so what this draws is what the ocean draws there.
shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform;

#define WATER_FOAM_CREST
#define WATER_SCATTER

#include "res://addons/pasture_3d/extras/shaders/water/water_common.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_surface.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_shading.gdshaderinc"
