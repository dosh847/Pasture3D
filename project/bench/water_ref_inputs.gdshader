// Pasture3D Water -- unlit readout of the reference fragment's inputs (PASTURE3D_WATER_REFERENCE_SPEC.md R6).
//
// water_ref_lit.gdshader's surface with WATER_DEBUG_REF_INPUTS: one raw input a pass, _debug_ref_value
// choosing which, split across the three channels (water_shading.gdshaderinc). Read through a float
// viewport, with the sun hidden, by WaterReferenceABGate.
shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform;

#define WATER_FOAM_CREST
#define WATER_SCATTER
#define WATER_DEBUG_REF_INPUTS

uniform int _debug_ref_value = 0;

#include "res://addons/pasture_3d/extras/shaders/water/water_common.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_surface.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_shading.gdshaderinc"
