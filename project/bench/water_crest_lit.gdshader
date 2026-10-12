// Pasture3D Water -- the lit (WATER_PBR) shading with FFT crest foam and nothing else, for
// WaterFFTWiringGate [L] (PASTURE3D_WATER_REFERENCE_SPEC.md R4, L1/L2). water_ocean.gdshader's crest path
// without its clipmap, terrain check and depth fade, so it runs on a plain mesh with no manager wiring
// beyond the profile upload.
shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform;

#define WATER_FOAM_CREST

#include "res://addons/pasture_3d/extras/shaders/water/water_common.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_surface.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_shading.gdshaderinc"
