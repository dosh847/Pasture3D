// Pasture3D Water -- unlit readout of the FFT's per-pixel shading inputs (PASTURE3D_WATER_REFERENCE_SPEC.md R3).
//
// water_body.gdshader's surface with WATER_DEBUG_FFT_SHADING: EMISSION.rg = the fragment's final slope
// (dh/dx, dh/dz) / 8 + 0.5, after normal strength and the normal fade; EMISSION.b = the crest foam after its
// fade. Read through a float viewport by WaterFFTWiringGate [N].
shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform;

#define WATER_DEBUG_FFT_SHADING
#define WATER_FOAM_CREST

#include "res://addons/pasture_3d/extras/shaders/water/water_common.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_waves.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_surface.gdshaderinc"
#include "res://addons/pasture_3d/extras/shaders/water/water_shading.gdshaderinc"
