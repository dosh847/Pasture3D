// Pasture3D Water — terrain check (PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md §I).
//
// Removes water that is certainly under land or over a region that is not loaded, by writing NaN into
// the vertex, as the terrain draws its holes. Included by clipmap wrappers that #define
// WATER_TERRAIN_CHECK; water_surface.gdshaderinc calls it last in vertex().
//
// It reads the terrain through GLOBAL uniforms the terrain publishes (Pasture3DMaterial), so the terrain
// knows nothing about water and any water shader can include this. With no terrain published,
// pasture3d_terrain is zero and every vertex is kept.
//
// The region map encoding is defined in Pasture3DData::region_map_encode and shaders/region_map.glsl; the
// part read here is: 0 no region, 0.25 indexed but not loaded, negative a coarse region, and
// |v| - 1 = slot | shift << 16. Pasture3DData::get_water_terrain_state mirrors this function step for step:
// RegionWaterGate fixes what the mirror says, and RegionWaterRenderProbe (windowed) that this agrees with it.

#ifndef WATER_TERRAIN_INC
#define WATER_TERRAIN_INC

// The reach of a removed vertex, in ring cells: the cell diagonal plus the geomorph, as the shore mask's 3.5.
// Overridable only so RegionWaterRenderProbe can show what 0 does.
#ifndef WATER_TERRAIN_REACH
#define WATER_TERRAIN_REACH 3.5
#endif

global uniform sampler2D pasture3d_region_map;
global uniform sampler2DArray pasture3d_height_maps;
global uniform sampler2DArray pasture3d_coarse_height_maps;
// (vertex_spacing, region_size, region_map_size, coarse_store_shift); region_size 0 = no terrain.
global uniform vec4 pasture3d_terrain;

group_uniforms body;
// Land has to stand this far above the water before the water under it is removed. Only water that is
// certainly covered goes; the depth buffer still draws the visible shoreline.
uniform float land_margin : hint_range(0.0, 50.0, 0.1) = 2.0;
group_uniforms;

// 0 no region (open sea, or beyond the world), 1 unloaded, 2 land, 3 terrain below the water.
int water_terrain_state(vec2 p_xz, float p_level) {
	float rs = pasture3d_terrain.y;
	if (rs <= 0.0) {
		return 0;
	}
	int ms = int(pasture3d_terrain.z);
	ivec2 v = ivec2(floor(p_xz / pasture3d_terrain.x + 0.5));
	ivec2 loc = ivec2(floor(vec2(v) / rs));
	ivec2 pos = loc + ivec2(ms / 2);
	if (pos.x < 0 || pos.y < 0 || pos.x >= ms || pos.y >= ms) {
		return 0;
	}
	float raw = texelFetch(pasture3d_region_map, pos, 0).r;
	int e = int(round(raw));
	if (e == 0) {
		// 0.25 (Pasture3DData::REGION_MAP_UNLOADED_TEXEL) is not an integer, so it rounds to 0 for every
		// other reader; only this check tells it from no region.
		return raw > 0.125 ? 1 : 0;
	}
	int id = abs(e) - 1;
	int slot = id & 0xFFFF;
	ivec2 local = v - loc * int(rs);
	float h;
	if (e < 0) {
		// A coarse region's lattice texel, stored upsampled at the coarse arrays' ratio.
		int s = (id >> 16) & 7;
		int q = s - int(pasture3d_terrain.w);
		h = texelFetch(pasture3d_coarse_height_maps, ivec3((local >> s) << q, slot), 0).r;
	} else {
		h = texelFetch(pasture3d_height_maps, ivec3(local, slot), 0).r;
	}
	return h >= p_level + land_margin ? 2 : 3;
}

// A NaN vertex takes every triangle using it, so the vertex is removed only when the whole reach of those
// triangles is hidden: its centre and the four corners at +-p_radius. Pasture3DData::is_water_hidden.
bool water_terrain_hides(vec2 p_xz, float p_level, float p_radius) {
	vec2 taps[5] = vec2[](vec2(0.0), vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(-1.0, 1.0), vec2(1.0, 1.0));
	for (int i = 0; i < 5; i++) {
		int st = water_terrain_state(p_xz + taps[i] * p_radius, p_level);
		if (st != 1 && st != 2) {
			return false;
		}
	}
	return true;
}

#endif // WATER_TERRAIN_INC
