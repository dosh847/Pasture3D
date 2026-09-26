// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(
//INSERT: REGION_MAP
// The region map: an RF texture, one texel per region location, offset by _region_map_size / 2. Each texel
// holds an exact integer (Pasture3DData::region_map_encode, the only other place this encoding is defined):
//   0          no region
//   (slot + 1) | color_only << 20
//              a Standard (texel ratio 1) region in the fine arrays (_height_maps, ...)
//   -((slot + 1) | shift << 16 | collapse << 19 | color_only << 20)
//              a coarse region, texel ratio 1 << shift, in the coarse arrays (_coarse_height_maps, ...)
//   0.25       a location the region index names but that is not loaded (the CPU map holds -(1 << 21)).
//              Not an integer: round() reads it as 0, no region, so no reader here pays to test for it.
// A reader that only knows "slot + 1" sees a coarse region as no region, and a flagged one as a slot past
// its bounds.
uniform highp sampler2D _region_map : filter_nearest, repeat_disable;
uniform int _region_map_size = 256;

// A region id: -1 for none, else slot | shift << 16 | collapse << 19 | color_only << 20. It is NOT an
// array layer: REGION_LAYER is (-1 stays -1, as the arrays were always read with no region).
#define REGION_SLOT(id) ((id) & 0xFFFF)
#define REGION_LAYER(id) ((id) < 0 ? -1 : ((id) & 0xFFFF))
#define REGION_SHIFT(id) (((id) >> 16) & 0x7)
#define REGION_COLLAPSE(id) ((((id) >> 19) & 0x1) != 0)
#define REGION_COLOR_ONLY(id) ((((id) >> 20) & 0x1) != 0)
#define REGION_COARSE(id) ((id) >= 0 && (((id) >> 16) & 0x7) != 0)

// Region id at map position `pos` (location + _region_map_size / 2), or -1 if none.
int region_map_slot(ivec2 pos) {
	if (uint(pos.x | pos.y) >= uint(_region_map_size)) {
		return -1;
	}
	int v = int(round(texelFetch(_region_map, pos, 0).r));
	return v == 0 ? -1 : abs(v) - 1;
}

//INSERT: REGION_FETCH
// Array reads that know a region's texel ratio (PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md §D). The coarse
// arrays hold every coarse region at one texel ratio, 1 << _coarse_store_shift (the finest coarse ratio
// loaded); a coarser region is stored upsampled and only its lattice texels are read for height.
uniform highp sampler2DArray _coarse_height_maps : repeat_disable;
uniform highp sampler2DArray _coarse_control_maps : repeat_disable;
uniform int _coarse_store_shift = 2;

// Height at a region's local vertex (0, 0), which is on every lattice; NaN with no region there.
float _region_origin_height(ivec2 p_loc) {
	int id = region_map_slot(p_loc + (_region_map_size / 2));
	if (id < 0) {
		return 0. / 0.;
	}
	return REGION_COARSE(id) ? texelFetch(_coarse_height_maps, ivec3(0, 0, REGION_SLOT(id)), 0).r :
			texelFetch(_height_maps, ivec3(0, 0, REGION_SLOT(id)), 0).r;
}

// Height at vertex p_local of the region at p_loc, where one coordinate of p_local is 0 (a neighbour's
// edge, reached from past another region's far side). Coarse: linear along the edge, and a lattice corner
// past the far end is the next region's origin (held when it is missing), as Pasture3DData::_coarse_height.
float _region_edge_height(ivec2 p_loc, ivec2 p_local, int p_id) {
	if (!REGION_COARSE(p_id)) {
		return texelFetch(_height_maps, ivec3(p_local, REGION_SLOT(p_id)), 0).r;
	}
	int s = REGION_SHIFT(p_id);
	int q = s - _coarse_store_shift;
	int slot = REGION_SLOT(p_id);
	int m = int(_region_size) >> s;
	ivec2 i0 = p_local >> s;
	ivec2 rem = p_local - (i0 << s);
	float h0 = texelFetch(_coarse_height_maps, ivec3(i0 << q, slot), 0).r;
	if (rem == ivec2(0)) {
		return h0;
	}
	ivec2 i1 = i0 + ivec2(rem.x > 0 ? 1 : 0, rem.y > 0 ? 1 : 0);
	float h1;
	if (i1.x < m && i1.y < m) {
		h1 = texelFetch(_coarse_height_maps, ivec3(i1 << q, slot), 0).r;
	} else {
		h1 = _region_origin_height(p_loc + ivec2(i1.x >= m ? 1 : 0, i1.y >= m ? 1 : 0));
		if (isnan(h1)) {
			h1 = texelFetch(_coarse_height_maps, ivec3(min(i1, ivec2(m - 1)) << q, slot), 0).r;
		}
	}
	return mix(h0, h1, float(rem.x + rem.y) / float(1 << s));
}

// Height at a fine vertex, in world vertex units (Pasture3DData::get_height_at_vertex): the texel on a
// Standard region, bilinear on the lattice of a coarse one, whose far corners are the neighbours' vertices.
// With no region the fine array is read at layer -1, as before coarse regions existed.
float vertex_height(vec2 p_pos) {
	ivec2 v = ivec2(round(p_pos));
	int rs = int(_region_size);
	ivec2 loc = ivec2(floor(vec2(v) * _region_texel_size));
	ivec2 local = v - loc * rs;
	int id = region_map_slot(loc + (_region_map_size / 2));
	if (!REGION_COARSE(id)) {
		return texelFetch(_height_maps, ivec3(local, REGION_LAYER(id)), 0).r;
	}
	int s = REGION_SHIFT(id);
	int q = s - _coarse_store_shift;
	int slot = REGION_SLOT(id);
	int m = rs >> s;
	ivec2 i0 = local >> s;
	ivec2 rem = local - (i0 << s);
	float c[4]; // (0,0) (1,0) (0,1) (1,1)
	for (int k = 0; k < 4; k++) {
		ivec2 d = ivec2(k & 1, k >> 1);
		if ((d.x > 0 && rem.x == 0) || (d.y > 0 && rem.y == 0)) {
			c[k] = 0.; // Weight 0 below
			continue;
		}
		ivec2 ic = i0 + d;
		if (ic.x < m && ic.y < m) {
			c[k] = texelFetch(_coarse_height_maps, ivec3(ic << q, slot), 0).r;
		} else {
			ivec2 n_loc = loc + ivec2(ic.x >= m ? 1 : 0, ic.y >= m ? 1 : 0);
			ivec2 n_local = (ic << s) - (n_loc - loc) * rs;
			int n_id = region_map_slot(n_loc + (_region_map_size / 2));
			c[k] = n_id >= 0 ? _region_edge_height(n_loc, n_local, n_id) :
					texelFetch(_coarse_height_maps, ivec3(min(ic, ivec2(m - 1)) << q, slot), 0).r;
		}
	}
	vec2 t = vec2(rem) / float(1 << s);
	return mix(mix(c[0], c[1], t.x), mix(c[2], c[3], t.x), t.y);
}

// Control word at an index from get_index_coord: the texel at or before it on a coarse region.
uint fetch_control(ivec3 p_index) {
	if (!REGION_COARSE(p_index.z)) {
		return floatBitsToUint(texelFetch(_control_maps, ivec3(p_index.xy, REGION_LAYER(p_index.z)), 0).r);
	}
	return floatBitsToUint(texelFetch(_coarse_control_maps,
			ivec3(p_index.xy >> _coarse_store_shift, REGION_SLOT(p_index.z)), 0).r);
}

// Texel ratio at a fine position, in world vertex units: 1 off a coarse region.
float region_ratio_at(vec2 p_pos) {
	int id = region_map_slot(ivec2(floor(p_pos * _region_texel_size)) + (_region_map_size / 2));
	return REGION_COARSE(id) ? float(1 << REGION_SHIFT(id)) : 1.;
}

)"
