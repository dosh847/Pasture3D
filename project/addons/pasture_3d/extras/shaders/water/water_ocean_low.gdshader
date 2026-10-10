// Pasture3D Water — Ocean, low tier.
// Clipmap geometry, reduced feature set: no scattering, no crest foam, no
// shadow receive. Spec §2.1.
shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform,
	shadows_disabled;

#define WATER_CLIPMAP
#define WATER_TERRAIN_CHECK
#define WATER_DEPTH_FADE
#define WATER_FOAM_SHORE

#include "res://addons/pasture_3d/extras/shaders/water/water_common.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_surface.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_shading.gdshaderinc"
