// Native spline-brush rasterisers (Round 2 perf). A faithful C++ port of the per-cell rasterisation in
// Pasture3DTerrainBrush (GDScript), which dominated large-edit bake time (~730 ms interpreted). These run
// the same SDF/chamfer + per-cell profile math natively and write into the layer via the existing
// (deferred) layer-write API, so they slot under the unchanged Round 1 orchestration. The GDScript loops
// are kept as a fallback / A-B reference. See PASTURE3D_BRUSH_PERF_ROUND2_SPEC.md.

#include "pasture_3d_data.h"
#include "pasture_3d_gpu_raster.h"
#include "pasture_3d_util.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>

#include <algorithm>
#include <cmath>
#include <vector>

using namespace godot;

namespace {

constexpr float RBIG = 1.0e9f;

// Linear lookup into a 0..1 ramp LUT. The brush always bakes a full LUT (curve or analytic default), so
// n>=2 in practice; the n==0/1 guards are just safety.
inline float raster_ramp(const PackedFloat32Array &lut, float x) {
	if (x < 0.f) {
		x = 0.f;
	} else if (x > 1.f) {
		x = 1.f;
	}
	const int n = lut.size();
	if (n == 0) {
		return x * x * (3.f - 2.f * x); // smoothstep(0,1,x) fallback
	}
	if (n == 1) {
		return lut[0];
	}
	const float f = x * (n - 1);
	int i0 = (int)f;
	if (i0 >= n - 1) {
		return lut[n - 1];
	}
	const float frac = f - (float)i0;
	return lut[i0] * (1.f - frac) + lut[i0 + 1] * frac;
}

// Two-pass chamfer distance transform, in place (port of Pasture3DTerrainBrush._chamfer).
void raster_chamfer(std::vector<float> &arr, int gw, int gh, float a, float b) {
	for (int iz = 0; iz < gh; iz++) {
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			const int i = row + ix;
			float d = arr[i];
			if (iz > 0) {
				const int up = i - gw;
				if (arr[up] + a < d) {
					d = arr[up] + a;
				}
				if (ix > 0 && arr[up - 1] + b < d) {
					d = arr[up - 1] + b;
				}
				if (ix < gw - 1 && arr[up + 1] + b < d) {
					d = arr[up + 1] + b;
				}
			}
			if (ix > 0 && arr[i - 1] + a < d) {
				d = arr[i - 1] + a;
			}
			arr[i] = d;
		}
	}
	for (int iz = gh - 1; iz >= 0; iz--) {
		const int row = iz * gw;
		for (int ix = gw - 1; ix >= 0; ix--) {
			const int i = row + ix;
			float d = arr[i];
			if (iz < gh - 1) {
				const int dn = i + gw;
				if (arr[dn] + a < d) {
					d = arr[dn] + a;
				}
				if (ix < gw - 1 && arr[dn + 1] + b < d) {
					d = arr[dn + 1] + b;
				}
				if (ix > 0 && arr[dn - 1] + b < d) {
					d = arr[dn - 1] + b;
				}
			}
			if (ix < gw - 1 && arr[i + 1] + a < d) {
				d = arr[i + 1] + a;
			}
			arr[i] = d;
		}
	}
}

// Signed distance field of a closed world polygon over the grid (port of _signed_distance_field).
// Fills `field` (gw*gh, positive inside / negative outside, metres); returns max interior distance.
float raster_sdf(const PackedVector2Array &poly, double min_x, double min_z, double vs, int gw, int gh, std::vector<float> &field) {
	const int n = gw * gh;
	const int pc = poly.size();
	std::vector<uint8_t> inside(n, 0);
	std::vector<float> xs;
	for (int iz = 0; iz < gh; iz++) {
		const double zc = min_z + iz * vs;
		xs.clear();
		for (int e = 0; e < pc; e++) {
			const Vector2 pa = poly[e];
			const Vector2 pb = poly[(e + 1) % pc];
			if ((pa.y <= zc && pb.y > zc) || (pb.y <= zc && pa.y > zc)) {
				const double tt = (zc - pa.y) / (pb.y - pa.y);
				xs.push_back((float)(pa.x + tt * (pb.x - pa.x)));
			}
		}
		std::sort(xs.begin(), xs.end());
		const int row = iz * gw;
		size_t k = 0;
		while (k + 1 < xs.size()) {
			int ix0 = (int)std::ceil((xs[k] - min_x) / vs);
			int ix1 = (int)std::floor((xs[k + 1] - min_x) / vs);
			if (ix0 < 0) {
				ix0 = 0;
			}
			if (ix1 > gw - 1) {
				ix1 = gw - 1;
			}
			for (int ix = ix0; ix <= ix1; ix++) {
				inside[row + ix] = 1;
			}
			k += 2;
		}
	}
	std::vector<float> din(n), dout(n);
	for (int i = 0; i < n; i++) {
		if (inside[i]) {
			din[i] = RBIG;
			dout[i] = 0.f;
		} else {
			din[i] = 0.f;
			dout[i] = RBIG;
		}
	}
	const float diag = (float)(vs * 1.4142135624);
	raster_chamfer(din, gw, gh, (float)vs, diag);
	raster_chamfer(dout, gw, gh, (float)vs, diag);
	field.assign(n, 0.f);
	float max_inside = 0.f;
	for (int i = 0; i < n; i++) {
		if (inside[i]) {
			field[i] = din[i];
			if (din[i] < RBIG && din[i] > max_inside) {
				max_inside = din[i];
			}
		} else {
			field[i] = -dout[i];
		}
	}
	return max_inside;
}

// Chamfer that carries two payloads with the nearest-feature distance (port of _chamfer_payload).
void raster_chamfer_payload(std::vector<float> &dist, std::vector<float> &p1, std::vector<float> &p2, int gw, int gh, float a, float b) {
	for (int iz = 0; iz < gh; iz++) {
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			const int i = row + ix;
			float bd = dist[i];
			int bj = -1;
			if (iz > 0) {
				const int up = i - gw;
				if (dist[up] + a < bd) { bd = dist[up] + a; bj = up; }
				if (ix > 0 && dist[up - 1] + b < bd) { bd = dist[up - 1] + b; bj = up - 1; }
				if (ix < gw - 1 && dist[up + 1] + b < bd) { bd = dist[up + 1] + b; bj = up + 1; }
			}
			if (ix > 0 && dist[i - 1] + a < bd) { bd = dist[i - 1] + a; bj = i - 1; }
			if (bj >= 0) { dist[i] = bd; p1[i] = p1[bj]; p2[i] = p2[bj]; }
		}
	}
	for (int iz = gh - 1; iz >= 0; iz--) {
		const int row = iz * gw;
		for (int ix = gw - 1; ix >= 0; ix--) {
			const int i = row + ix;
			float bd = dist[i];
			int bj = -1;
			if (iz < gh - 1) {
				const int dn = i + gw;
				if (dist[dn] + a < bd) { bd = dist[dn] + a; bj = dn; }
				if (ix < gw - 1 && dist[dn + 1] + b < bd) { bd = dist[dn + 1] + b; bj = dn + 1; }
				if (ix > 0 && dist[dn - 1] + b < bd) { bd = dist[dn - 1] + b; bj = dn - 1; }
			}
			if (ix < gw - 1 && dist[i + 1] + a < bd) { bd = dist[i + 1] + a; bj = i + 1; }
			if (bj >= 0) { dist[i] = bd; p1[i] = p1[bj]; p2[i] = p2[bj]; }
		}
	}
}

// Feature field of a world-space polyline over the grid (port of _polyline_field). Fills lat / base_y /
// along (size gw*gh); returns the polyline's total arc length.
float raster_polyline_field(const PackedVector3Array &pts, double min_x, double min_z, double vs, int gw, int gh,
		std::vector<float> &lat, std::vector<float> &base_y, std::vector<float> &along) {
	const int n = gw * gh;
	lat.assign(n, RBIG);
	base_y.assign(n, 0.f);
	along.assign(n, 0.f);
	const double sample = vs * 0.5;
	double run = 0.0;
	const int np = pts.size();
	for (int k = 0; k < np - 1; k++) {
		const Vector3 a = pts[k];
		const Vector3 b = pts[k + 1];
		const double ax = a.x;
		const double az = a.z;
		const double seg = std::sqrt((b.x - ax) * (b.x - ax) + (b.z - az) * (b.z - az));
		const double along_a = run;
		run += seg;
		int steps = (int)std::ceil(seg / sample);
		if (steps < 1) {
			steps = 1;
		}
		for (int s = 0; s <= steps; s++) {
			const double tt = (double)s / (double)steps;
			const int ix = (int)std::lround((ax + (b.x - ax) * tt - min_x) / vs);
			const int iz = (int)std::lround((az + (b.z - az) * tt - min_z) / vs);
			if (ix >= 0 && ix < gw && iz >= 0 && iz < gh) {
				const int idx = iz * gw + ix;
				lat[idx] = 0.f;
				base_y[idx] = (float)(a.y + (b.y - a.y) * tt);
				along[idx] = (float)(along_a + seg * tt);
			}
		}
	}
	raster_chamfer_payload(lat, base_y, along, gw, gh, (float)vs, (float)(vs * 1.4142135624));
	return (float)run;
}

} // namespace

void Pasture3DData::_stamp_write(Pasture3DLayer *p_layer, const int p_layer_id, const bool p_composite,
		Vector2i &r_loc, Pasture3DRegion *&r_region, const Vector3 &p_pos, const real_t p_value, const int p_blend) {
	// p_blend matches Pasture3DLayer::BlendMode / the GDScript BLEND_* consts: 0=REPLACE,1=ADD,2=MAX,3=MIN.
	if (!p_layer) {
		// No stack / invalid layer: destructive fallback (the deferred partial path normally has a layer).
		if (p_blend == 1) {
			set_height(p_pos, get_height(p_pos) + p_value);
		} else {
			set_height(p_pos, p_value);
		}
		return;
	}
	Vector2i region_loc;
	const Vector2i img_pos = _global_to_region_pixel(p_pos, region_loc);
	if (region_loc != r_loc) { // cache the region across a run of same-region cells
		r_loc = region_loc;
		r_region = get_region_ptr(region_loc);
	}
	if (!r_region || r_region->is_deleted()) {
		return;
	}
	// Combine with any same-layer value already written THIS bake, by the brush's blend mode, so two
	// overlapping tools on one layer stack correctly (MAX keeps the taller, MIN the deeper, ADD sums)
	// instead of the later tool overwriting the earlier one — the "cut" two mounds carved in each other.
	// The bake clears the layer in the box first, so the first tool finds it uncovered and just writes.
	real_t v = p_value;
	if (p_layer->get_weight(region_loc, img_pos) > 0.f) {
		const real_t cur = p_layer->get_value(region_loc, img_pos);
		switch (p_blend) {
			case 1: v = cur + p_value; break;   // ADD
			case 2: v = MAX(cur, p_value); break; // MAX
			case 3: v = MIN(cur, p_value); break; // MIN
			default: break;                       // REPLACE: last write wins
		}
	}
	p_layer->set_sample(region_loc, img_pos, v, 1.0);
	r_region->set_modified(true);
	if (p_composite) {
		// Full-refresh path: keep the public API's per-pixel composite (layer-vs-below) up to date.
		composite_region(region_loc, Rect2i(img_pos, V2I(1)), false);
	}
}

// Floor division (toward -inf), for region coords that can be negative.
static inline int _floordiv(const int a, const int b) {
	int q = a / b;
	if ((a % b != 0) && ((a < 0) != (b < 0))) {
		q--;
	}
	return q;
}

void Pasture3DData::_apply_stamp_block(Pasture3DLayer *p_layer, const int p_min_px, const int p_min_pz,
		const int p_gw, const int p_gh, const float *p_vals, const int p_blend) {
	if (!p_layer) {
		return;
	}
	const int rs = _region_size;
	const int ts = p_layer->get_tile_size();
	if (rs < 1 || ts < 1) {
		return;
	}
	const int px_lo = p_min_px, px_hi = p_min_px + p_gw; // box world-pixel range [lo, hi)
	const int pz_lo = p_min_pz, pz_hi = p_min_pz + p_gh;
	const int rx0 = _floordiv(px_lo, rs), rx1 = _floordiv(px_hi - 1, rs);
	const int rz0 = _floordiv(pz_lo, rs), rz1 = _floordiv(pz_hi - 1, rs);

	for (int rz = rz0; rz <= rz1; rz++) {
		for (int rx = rx0; rx <= rx1; rx++) {
			const Vector2i region_loc(rx, rz);
			Pasture3DRegion *region = get_region_ptr(region_loc);
			if (!region || region->is_deleted()) {
				continue; // only write where a region exists (matches _stamp_write)
			}
			const int gx = rx * rs, gz = rz * rs; // region's global pixel origin
			// Region-local pixel rect covered by the box.
			const int lpx0 = MAX(0, px_lo - gx), lpx1 = MIN(rs, px_hi - gx);
			const int lpz0 = MAX(0, pz_lo - gz), lpz1 = MIN(rs, pz_hi - gz);
			if (lpx0 >= lpx1 || lpz0 >= lpz1) {
				continue;
			}
			const int tx0 = lpx0 / ts, tx1 = (lpx1 - 1) / ts;
			const int tz0 = lpz0 / ts, tz1 = (lpz1 - 1) / ts;
			bool region_touched = false;
			for (int tz = tz0; tz <= tz1; tz++) {
				for (int tx = tx0; tx <= tx1; tx++) {
					const int bx = tx * ts, bz = tz * ts;
					const int x0 = MAX(lpx0, bx), x1 = MIN(lpx1, bx + ts);
					const int z0 = MAX(lpz0, bz), z1 = MIN(lpz1, bz + ts);
					if (x0 >= x1 || z0 >= z1) {
						continue;
					}
					// Pre-scan: skip tiles the feature doesn't touch (e.g. corner tiles of a circular dome)
					// so we don't allocate/dirty empty tiles the per-cell path never created.
					bool any = false;
					for (int py = z0; py < z1 && !any; py++) {
						const float *vrow = &p_vals[(size_t)(gz + py - p_min_pz) * p_gw];
						const int ix0 = gx + x0 - p_min_px, ix1 = gx + x1 - p_min_px;
						for (int ix = ix0; ix < ix1; ix++) {
							if (!std::isnan(vrow[ix])) {
								any = true;
								break;
							}
						}
					}
					if (!any) {
						continue;
					}
					Ref<Image> tile = p_layer->get_or_create_tile(region_loc, Vector2i(tx, tz));
					if (tile.is_null() || tile->get_format() != Image::FORMAT_RGF) {
						continue; // batched path is RGF-only; non-RGF shouldn't occur on a non-base overlay
					}
					PackedByteArray data = tile->get_data();
					float *f = reinterpret_cast<float *>(data.ptrw()); // RGF: [r,g] per pixel, stride 2
					bool tile_touched = false;
					for (int py = z0; py < z1; py++) {
						const int iz = gz + py - p_min_pz; // box-grid row
						const float *vrow = &p_vals[(size_t)iz * p_gw];
						const int ly = py - bz;
						for (int px = x0; px < x1; px++) {
							const int ix = gx + px - p_min_px;
							const float v = vrow[ix];
							if (std::isnan(v)) {
								continue;
							}
							const int li = (ly * ts + (px - bx)) * 2;
							float out = v;
							if (f[li + 1] > 0.f) { // already written THIS bake (same-layer blend)
								const float cur = f[li];
								switch (p_blend) {
									case 1: out = cur + v; break; // ADD
									case 2: out = MAX(cur, v); break; // MAX
									case 3: out = MIN(cur, v); break; // MIN
									default: break; // REPLACE
								}
							}
							f[li] = out;
							f[li + 1] = 1.f;
							tile_touched = true;
						}
					}
					if (tile_touched) {
						tile->set_data(ts, ts, false, Image::FORMAT_RGF, data);
						region_touched = true;
					}
				}
			}
			if (region_touched) {
				region->set_modified(true);
			}
		}
	}
}

void Pasture3DData::_apply_control_block(Pasture3DLayer *p_layer, const int p_min_px, const int p_min_pz,
		const int p_gw, const int p_gh, const uint32_t *p_ctrl, const uint8_t *p_mask) {
	if (!p_layer) {
		return;
	}
	const int rs = _region_size;
	const int ts = p_layer->get_tile_size();
	if (rs < 1 || ts < 1) {
		return;
	}
	const int px_lo = p_min_px, px_hi = p_min_px + p_gw;
	const int pz_lo = p_min_pz, pz_hi = p_min_pz + p_gh;
	const int rx0 = _floordiv(px_lo, rs), rx1 = _floordiv(px_hi - 1, rs);
	const int rz0 = _floordiv(pz_lo, rs), rz1 = _floordiv(pz_hi - 1, rs);

	for (int rz = rz0; rz <= rz1; rz++) {
		for (int rx = rx0; rx <= rx1; rx++) {
			const Vector2i region_loc(rx, rz);
			Pasture3DRegion *region = get_region_ptr(region_loc);
			if (!region || region->is_deleted()) {
				continue;
			}
			const int gx = rx * rs, gz = rz * rs;
			const int lpx0 = MAX(0, px_lo - gx), lpx1 = MIN(rs, px_hi - gx);
			const int lpz0 = MAX(0, pz_lo - gz), lpz1 = MIN(rs, pz_hi - gz);
			if (lpx0 >= lpx1 || lpz0 >= lpz1) {
				continue;
			}
			const int tx0 = lpx0 / ts, tx1 = (lpx1 - 1) / ts;
			const int tz0 = lpz0 / ts, tz1 = (lpz1 - 1) / ts;
			bool region_touched = false;
			for (int tz = tz0; tz <= tz1; tz++) {
				for (int tx = tx0; tx <= tx1; tx++) {
					const int bx = tx * ts, bz = tz * ts;
					const int x0 = MAX(lpx0, bx), x1 = MIN(lpx1, bx + ts);
					const int z0 = MAX(lpz0, bz), z1 = MIN(lpz1, bz + ts);
					if (x0 >= x1 || z0 >= z1) {
						continue;
					}
					bool any = false;
					for (int py = z0; py < z1 && !any; py++) {
						const uint8_t *mrow = &p_mask[(size_t)(gz + py - p_min_pz) * p_gw];
						for (int ix = gx + x0 - p_min_px, ixe = gx + x1 - p_min_px; ix < ixe; ix++) {
							if (mrow[ix]) {
								any = true;
								break;
							}
						}
					}
					if (!any) {
						continue;
					}
					Ref<Image> tile = p_layer->get_or_create_tile(region_loc, Vector2i(tx, tz));
					if (tile.is_null() || tile->get_format() != Image::FORMAT_RGF) {
						continue;
					}
					PackedByteArray data = tile->get_data();
					float *f = reinterpret_cast<float *>(data.ptrw());
					bool tile_touched = false;
					for (int py = z0; py < z1; py++) {
						const int idx_row = (gz + py - p_min_pz) * p_gw;
						const int ly = py - bz;
						for (int px = x0; px < x1; px++) {
							const int idx = idx_row + (gx + px - p_min_px);
							if (!p_mask[idx]) {
								continue;
							}
							const int li = (ly * ts + (px - bx)) * 2;
							f[li] = as_float(p_ctrl[idx]); // control bits as float (REPLACE; no numeric blend)
							f[li + 1] = 1.f;
							tile_touched = true;
						}
					}
					if (tile_touched) {
						tile->set_data(ts, ts, false, Image::FORMAT_RGF, data);
						region_touched = true;
					}
				}
			}
			if (region_touched) {
				region->set_modified(true);
			}
		}
	}
}

// ---- Closed-loop dome/plateau (Pasture3DMound) ----
void Pasture3DData::stamp_mound_loop(const int p_layer_id, const PackedVector2Array &p_poly, const AABB &p_clip, const Dictionary &p_params, const PackedFloat32Array &p_lut) {
	if (p_poly.size() < 3) {
		return;
	}
	const double min_x = p_params.get("min_x", 0.0);
	const double min_z = p_params.get("min_z", 0.0);
	const double vs = p_params.get("vs", 1.0);
	const int gw = (int)p_params.get("gw", 0);
	const int gh = (int)p_params.get("gh", 0);
	if (gw < 1 || gh < 1) {
		return;
	}

	// Signed-distance field: GPU analytic when the box is large enough and a local RenderingDevice exists,
	// else the C++ serial chamfer. Three-tier fallback GPU -> C++ -> GDScript (spec §4). The GPU path is a
	// drop-in: it fills `field` + `max_inside` identically in shape, so the per-cell loop below is unchanged
	// and the only behavioural change is analytic-exact vs chamfer-approximate distance (A/B-validated §7).
	std::vector<float> field;
	float max_inside = 0.f;
	bool got_field = false;
	const int threshold = _gpu_raster_threshold();
	if (threshold > 0 && (gw * gh) >= threshold) {
		Pasture3DGPURaster *gpu = _ensure_gpu_raster();
		if (gpu) {
			got_field = gpu->closed_loop_field(p_poly, min_x, min_z, vs, gw, gh, field, max_inside);
		}
	}
	if (!got_field) {
		max_inside = raster_sdf(p_poly, min_x, min_z, vs, gw, gh, field);
	}

	const double height = p_params.get("height", 0.0);
	const bool capped = p_params.get("capped", false);
	const bool invert = p_params.get("invert", false);
	const double falloff_width = p_params.get("falloff_width", 0.0);
	const double edge_offset = p_params.get("edge_offset", 0.0);
	const bool relative = p_params.get("relative_to_terrain", true);
	const double plane_y = p_params.get("plane_y", 0.0);
	const int blend = (int)p_params.get("blend", 0);
	const bool composite = p_params.get("composite", true);
	const double noise_strength = p_params.get("noise_strength", 0.0);
	Object *noise_obj = p_params.get("noise", Variant());
	Ref<FastNoiseLite> noise = Object::cast_to<FastNoiseLite>(noise_obj);

	const double sign = invert ? -1.0 : 1.0;
	const double dome_denom = MAX(max_inside + edge_offset, 0.001);
	const double ramp_denom = MAX(falloff_width, 0.001);
	const bool add = (blend == 1); // BLEND_ADD

	Pasture3DLayer *wlayer = _layer_stack.is_null() ? nullptr : _layer_stack->get_layer_ptr(p_layer_id);
	Vector2i wloc(0x7fffffff, 0x7fffffff);
	Pasture3DRegion *wregion = nullptr;
	// Below-layer base: the composite of layers beneath this brush's, so it samples the ground under its
	// own layer (not the full terrain) and features stop climbing each other. NaN/empty => fall back.
	const PackedFloat32Array base_below = p_params.get("base_below", PackedFloat32Array());
	const bool has_below = base_below.size() == gw * gh;

	// Batched raw-tile apply path (Phase 1b): accumulate per-cell values into a box buffer, then commit them
	// to the layer one tile at a time (no per-cell dict lookup / set_pixelv) — the cost that dominated
	// terrain-scale bakes. Used for the common deferred, non-base overlay case; otherwise fall back to
	// per-cell _stamp_write (full-refresh composite, no layer, or a dense Base target). NaN = no write.
	const bool batched = wlayer && !composite && !wlayer->is_base();
	std::vector<float> vals;
	if (batched) {
		vals.assign((size_t)gw * gh, NAN);
	}

	const bool has_clip = p_clip.size != Vector3();
	const double cx0 = p_clip.position.x;
	const double cx1 = p_clip.position.x + p_clip.size.x;
	const double cz0 = p_clip.position.z;
	const double cz1 = p_clip.position.z + p_clip.size.z;

	for (int iz = 0; iz < gh; iz++) {
		const double z = min_z + iz * vs;
		if (has_clip && (z < cz0 || z >= cz1)) {
			continue;
		}
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			const double signed_d = (double)field[row + ix] + edge_offset;
			if (signed_d <= 0.0) {
				continue;
			}
			const float profile = raster_ramp(p_lut, (float)(signed_d / (capped ? ramp_denom : dome_denom)));
			if (profile <= 0.f) {
				continue;
			}
			const double x = min_x + ix * vs;
			if (has_clip && (x < cx0 || x >= cx1)) {
				continue;
			}
			const Vector3 pos(x, 0.0, z);
			double base_y;
			if (relative) {
				const float bb = has_below ? base_below[row + ix] : (float)NAN;
				base_y = std::isnan(bb) ? (double)get_height(pos) : (double)bb;
			} else {
				base_y = plane_y;
			}
			double amp = sign * height * profile;
			if (noise.is_valid()) {
				amp += noise_strength * noise->get_noise_2d(x, z) * profile;
			}
			const double value = add ? amp : (base_y + amp);
			if (batched) {
				vals[row + ix] = (float)value;
			} else {
				_stamp_write(wlayer, p_layer_id, composite, wloc, wregion, pos, value, blend);
			}
		}
	}

	if (batched) {
		const int min_px = (int)std::lround(min_x / vs);
		const int min_pz = (int)std::lround(min_z / vs);
		_apply_stamp_block(wlayer, min_px, min_pz, gw, gh, vals.data(), blend);
	}
}

// ---- Open-polyline crest (Pasture3DRidge) ----
void Pasture3DData::stamp_ridge_line(const int p_layer_id, const PackedVector3Array &p_pts, const AABB &p_clip, const Dictionary &p_params, const PackedFloat32Array &p_lut) {
	if (p_pts.size() < 2) {
		return;
	}
	const double min_x = p_params.get("min_x", 0.0);
	const double min_z = p_params.get("min_z", 0.0);
	const double vs = p_params.get("vs", 1.0);
	const int gw = (int)p_params.get("gw", 0);
	const int gh = (int)p_params.get("gh", 0);
	if (gw < 1 || gh < 1) {
		return;
	}

	std::vector<float> lat, base_yf, along;
	const float total = raster_polyline_field(p_pts, min_x, min_z, vs, gw, gh, lat, base_yf, along);

	const double crest_height = p_params.get("crest_height", 0.0);
	const double width = p_params.get("width", 0.0);
	const double falloff = p_params.get("falloff", 0.0);
	const bool invert = p_params.get("invert", false);
	const bool follow = p_params.get("follow_spline_height", true);
	const double taper_ends = p_params.get("taper_ends", 0.0);
	const int blend = (int)p_params.get("blend", 0);
	const bool composite = p_params.get("composite", true);
	const double noise_strength = p_params.get("noise_strength", 0.0);
	// Slope tilt (0..1): drape the cross-section onto the ground beneath. 0 = level (anchor stays at the
	// crest reference); 1 = the anchor follows the per-cell below-ground, so the ridge banks onto a hill.
	const double slope_tilt = CLAMP((double)p_params.get("slope_tilt", 0.0), 0.0, 1.0);
	Object *noise_obj = p_params.get("noise", Variant());
	Ref<FastNoiseLite> noise = Object::cast_to<FastNoiseLite>(noise_obj);

	const double sign = invert ? -1.0 : 1.0;
	const double reach = width + falloff;
	const double width_d = MAX(width, 0.001);
	const double falloff_d = MAX(falloff, 0.001);
	const float edge_val = raster_ramp(p_lut, 1.0f); // _cross at t=1
	const bool add = (blend == 1);

	Pasture3DLayer *wlayer = _layer_stack.is_null() ? nullptr : _layer_stack->get_layer_ptr(p_layer_id);
	Vector2i wloc(0x7fffffff, 0x7fffffff);
	Pasture3DRegion *wregion = nullptr;
	// Below-layer base: the composite of layers beneath this brush's, so it samples the ground under its
	// own layer (not the full terrain) and features stop climbing each other. NaN/empty => fall back.
	const PackedFloat32Array base_below = p_params.get("base_below", PackedFloat32Array());
	const bool has_below = base_below.size() == gw * gh;

	const bool batched = wlayer && !composite && !wlayer->is_base(); // Phase 1b batched raw-tile apply
	std::vector<float> vals;
	if (batched) {
		vals.assign((size_t)gw * gh, NAN);
	}

	const bool has_clip = p_clip.size != Vector3();
	const double cx0 = p_clip.position.x;
	const double cx1 = p_clip.position.x + p_clip.size.x;
	const double cz0 = p_clip.position.z;
	const double cz1 = p_clip.position.z + p_clip.size.z;

	for (int iz = 0; iz < gh; iz++) {
		const double z = min_z + iz * vs;
		if (has_clip && (z < cz0 || z >= cz1)) {
			continue;
		}
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			const int i = row + ix;
			const double latd = (double)lat[i];
			if (latd > reach) {
				continue;
			}
			const double x = min_x + ix * vs;
			if (has_clip && (x < cx0 || x >= cx1)) {
				continue;
			}
			const Vector3 pos(x, 0.0, z);
			double by;
			if (follow) {
				by = (double)base_yf[i];
			} else {
				const float bb = has_below ? base_below[i] : (float)NAN;
				by = std::isnan(bb) ? (double)get_height(pos) : (double)bb;
			}
			if (slope_tilt > 0.0) {
				// Blend the anchor toward the per-cell ground so the cross-section drapes onto the slope.
				const float bb = has_below ? base_below[i] : (float)NAN;
				const double ground = std::isnan(bb) ? (double)get_height(pos) : (double)bb;
				by += (ground - by) * slope_tilt;
			}
			double e = 1.0;
			if (taper_ends > 0.0) {
				const double al = (double)along[i];
				const double d = MIN(al, (double)total - al);
				e = CLAMP(d / taper_ends, 0.0, 1.0);
			}
			double p;
			if (latd <= width) {
				p = raster_ramp(p_lut, (float)(latd / width_d));
			} else {
				p = edge_val * (1.0 - CLAMP((latd - width) / falloff_d, 0.0, 1.0));
			}
			if (p > 0.0) {
				double amp = sign * crest_height * p * e;
				if (noise.is_valid()) {
					amp += noise_strength * noise->get_noise_2d(x, z) * p;
				}
				const double value = add ? amp : (by + amp);
				if (batched) {
					vals[i] = (float)value;
				} else {
					_stamp_write(wlayer, p_layer_id, composite, wloc, wregion, pos, value, blend);
				}
			}
		}
	}

	if (batched) {
		_apply_stamp_block(wlayer, (int)std::lround(min_x / vs), (int)std::lround(min_z / vs), gw, gh, vals.data(), blend);
	}
}

// ---- Open-polyline channel (Pasture3DTrough) ----
void Pasture3DData::stamp_trough_line(const int p_layer_id, const PackedVector3Array &p_pts, const AABB &p_clip, const Dictionary &p_params, const PackedFloat32Array &p_lut) {
	if (p_pts.size() < 2) {
		return;
	}
	const double min_x = p_params.get("min_x", 0.0);
	const double min_z = p_params.get("min_z", 0.0);
	const double vs = p_params.get("vs", 1.0);
	const int gw = (int)p_params.get("gw", 0);
	const int gh = (int)p_params.get("gh", 0);
	if (gw < 1 || gh < 1) {
		return;
	}

	std::vector<float> lat, base_yf, along;
	const float total = raster_polyline_field(p_pts, min_x, min_z, vs, gw, gh, lat, base_yf, along);

	const double bed_half_width = p_params.get("bed_half_width", 0.0);
	const double bank_width = p_params.get("bank_width", 0.0);
	const double falloff = p_params.get("falloff", 0.0);
	const double depth = p_params.get("depth", 0.0);
	const bool flat_bed = p_params.get("flat_bed", true);
	const bool follow = p_params.get("follow_spline_height", true);
	const double taper_ends = p_params.get("taper_ends", 0.0);
	const int blend = (int)p_params.get("blend", 0);
	const bool composite = p_params.get("composite", true);
	const double noise_strength = p_params.get("noise_strength", 0.0);
	// Slope tilt (0..1): drape the channel's rim reference onto the ground beneath, so a trough cut into
	// a hillside banks with the slope instead of holding a level rim. 0 = level; 1 = follows the ground.
	const double slope_tilt = CLAMP((double)p_params.get("slope_tilt", 0.0), 0.0, 1.0);
	Object *noise_obj = p_params.get("noise", Variant());
	Ref<FastNoiseLite> noise = Object::cast_to<FastNoiseLite>(noise_obj);

	const double reach = bed_half_width + bank_width + falloff;
	const double span = bed_half_width + bank_width;
	const double bank_d = MAX(bank_width, 0.001);
	const double span_d = MAX(span, 0.001);
	const double depth_d = MAX(depth, 0.001);
	const bool add = (blend == 1);

	Pasture3DLayer *wlayer = _layer_stack.is_null() ? nullptr : _layer_stack->get_layer_ptr(p_layer_id);
	Vector2i wloc(0x7fffffff, 0x7fffffff);
	Pasture3DRegion *wregion = nullptr;
	// Below-layer base: the composite of layers beneath this brush's, so it samples the ground under its
	// own layer (not the full terrain) and features stop climbing each other. NaN/empty => fall back.
	const PackedFloat32Array base_below = p_params.get("base_below", PackedFloat32Array());
	const bool has_below = base_below.size() == gw * gh;

	const bool batched = wlayer && !composite && !wlayer->is_base(); // Phase 1b batched raw-tile apply
	std::vector<float> vals;
	if (batched) {
		vals.assign((size_t)gw * gh, NAN);
	}

	const bool has_clip = p_clip.size != Vector3();
	const double cx0 = p_clip.position.x;
	const double cx1 = p_clip.position.x + p_clip.size.x;
	const double cz0 = p_clip.position.z;
	const double cz1 = p_clip.position.z + p_clip.size.z;

	for (int iz = 0; iz < gh; iz++) {
		const double z = min_z + iz * vs;
		if (has_clip && (z < cz0 || z >= cz1)) {
			continue;
		}
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			const int i = row + ix;
			const double latd = (double)lat[i];
			if (latd > reach) {
				continue;
			}
			const double x = min_x + ix * vs;
			if (has_clip && (x < cx0 || x >= cx1)) {
				continue;
			}
			const Vector3 pos(x, 0.0, z);
			double top_y;
			if (follow) {
				top_y = (double)base_yf[i];
			} else {
				const float bb = has_below ? base_below[i] : (float)NAN;
				top_y = std::isnan(bb) ? (double)get_height(pos) : (double)bb;
			}
			if (slope_tilt > 0.0) {
				// Blend the rim toward the per-cell ground so the channel drapes onto the slope.
				const float bb = has_below ? base_below[i] : (float)NAN;
				const double ground = std::isnan(bb) ? (double)get_height(pos) : (double)bb;
				top_y += (ground - top_y) * slope_tilt;
			}
			double e = 1.0;
			if (taper_ends > 0.0) {
				const double al = (double)along[i];
				const double d = MIN(al, (double)total - al);
				e = CLAMP(d / taper_ends, 0.0, 1.0);
			}
			const double bed_y = top_y - depth * e;
			double h;
			if (flat_bed) {
				if (latd <= bed_half_width) {
					h = bed_y;
				} else if (latd <= span) {
					const double t = (double)raster_ramp(p_lut, (float)((latd - bed_half_width) / bank_d));
					h = bed_y + (top_y - bed_y) * t;
				} else {
					h = top_y;
				}
			} else {
				if (latd <= span) {
					const double t = (double)raster_ramp(p_lut, (float)(latd / span_d));
					h = bed_y + (top_y - bed_y) * t;
				} else {
					h = top_y;
				}
			}
			if (noise.is_valid() && h < top_y) {
				const double mask = CLAMP((top_y - h) / depth_d, 0.0, 1.0);
				h = MIN(h + noise_strength * noise->get_noise_2d(x, z) * mask, top_y);
			}
			const double value = add ? (h - top_y) : h;
			if (batched) {
				vals[i] = (float)value;
			} else {
				_stamp_write(wlayer, p_layer_id, composite, wloc, wregion, pos, value, blend);
			}
		}
	}

	if (batched) {
		_apply_stamp_block(wlayer, (int)std::lround(min_x / vs), (int)std::lround(min_z / vs), gw, gh, vals.data(), blend);
	}
}

// ---- Closed-loop source relief (Pasture3DPlow) ----
void Pasture3DData::stamp_plow_loop(const int p_layer_id, const PackedVector2Array &p_poly, const AABB &p_clip, const Dictionary &p_params, const PackedFloat32Array &p_lut, const PackedFloat32Array &p_src_data) {
	if (p_poly.size() < 3) {
		return;
	}
	const double min_x = p_params.get("min_x", 0.0);
	const double min_z = p_params.get("min_z", 0.0);
	const double vs = p_params.get("vs", 1.0);
	const int gw = (int)p_params.get("gw", 0);
	const int gh = (int)p_params.get("gh", 0);
	if (gw < 1 || gh < 1) {
		return;
	}

	// Field: GPU analytic when the box is large enough + a local RD exists, else the C++ chamfer (Plow/Splat
	// ignore max_inside; they normalise on falloff_width). Same 3-tier fallback as Mound (spec §4).
	std::vector<float> field;
	{
		bool got_field = false;
		const int threshold = _gpu_raster_threshold();
		if (threshold > 0 && (gw * gh) >= threshold) {
			Pasture3DGPURaster *gpu = _ensure_gpu_raster();
			if (gpu) {
				float mi_unused = 0.f;
				got_field = gpu->closed_loop_field(p_poly, min_x, min_z, vs, gw, gh, field, mi_unused);
			}
		}
		if (!got_field) {
			raster_sdf(p_poly, min_x, min_z, vs, gw, gh, field);
		}
	}

	const double height_scale = p_params.get("height_scale", 0.0);
	const double height_offset = p_params.get("height_offset", 0.5);
	const double edge_offset = p_params.get("edge_offset", 0.0);
	const double falloff_width = p_params.get("falloff_width", 0.0);
	const bool relative = p_params.get("relative_to_terrain", true);
	const double plane_y = p_params.get("plane_y", 0.0);
	const int blend = (int)p_params.get("blend", 1);
	const bool composite = p_params.get("composite", true);
	const double src_strength = p_params.get("src_strength", 1.0);
	const double tile_size = MAX((double)p_params.get("tile_size", 16.0), 0.0001);
	const int source = (int)p_params.get("source", 0); // 0=NOISE 1=TEXTURE 2=MATERIAL
	const int data_w = (int)p_params.get("data_w", 0);
	const int data_h = (int)p_params.get("data_h", 0);
	Object *noise_obj = p_params.get("noise", Variant());
	Ref<FastNoiseLite> noise = Object::cast_to<FastNoiseLite>(noise_obj);

	const double ramp_denom = MAX(falloff_width, 0.001);
	const bool add = (blend == 1); // BLEND_ADD

	Pasture3DLayer *wlayer = _layer_stack.is_null() ? nullptr : _layer_stack->get_layer_ptr(p_layer_id);
	Vector2i wloc(0x7fffffff, 0x7fffffff);
	Pasture3DRegion *wregion = nullptr;
	// Below-layer base: the composite of layers beneath this brush's, so it samples the ground under its
	// own layer (not the full terrain) and features stop climbing each other. NaN/empty => fall back.
	const PackedFloat32Array base_below = p_params.get("base_below", PackedFloat32Array());
	const bool has_below = base_below.size() == gw * gh;

	const bool batched = wlayer && !composite && !wlayer->is_base(); // Phase 1b batched raw-tile apply
	std::vector<float> vals;
	if (batched) {
		vals.assign((size_t)gw * gh, NAN);
	}

	const bool has_clip = p_clip.size != Vector3();
	const double cx0 = p_clip.position.x;
	const double cx1 = p_clip.position.x + p_clip.size.x;
	const double cz0 = p_clip.position.z;
	const double cz1 = p_clip.position.z + p_clip.size.z;

	for (int iz = 0; iz < gh; iz++) {
		const double z = min_z + iz * vs;
		if (has_clip && (z < cz0 || z >= cz1)) {
			continue;
		}
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			const double signed_d = (double)field[row + ix] + edge_offset;
			if (signed_d <= 0.0) {
				continue;
			}
			const double mask = raster_ramp(p_lut, (float)(signed_d / ramp_denom));
			if (mask <= 0.0) {
				continue;
			}
			const double x = min_x + ix * vs;
			if (has_clip && (x < cx0 || x >= cx1)) {
				continue;
			}
			// Source value in [0,1] (mirrors Pasture3DPlow._sample01).
			double sv;
			if (source == 0) {
				sv = noise.is_valid() ? CLAMP(noise->get_noise_2d(x, z) * 0.5 + 0.5, 0.0, 1.0) : height_offset;
			} else if (p_src_data.is_empty() || data_w <= 0 || data_h <= 0) {
				sv = height_offset;
			} else {
				const double u = (x / tile_size) - std::floor(x / tile_size);
				const double t = (z / tile_size) - std::floor(z / tile_size);
				int px = (int)(u * data_w);
				int py = (int)(t * data_h);
				px = CLAMP(px, 0, data_w - 1);
				py = CLAMP(py, 0, data_h - 1);
				sv = p_src_data[py * data_w + px];
			}
			double amp = height_scale * (sv - height_offset) * mask * src_strength;
			if (std::fabs(amp) < 0.0001) {
				continue;
			}
			const Vector3 pos(x, 0.0, z);
			double base_y;
			if (relative) {
				const float bb = has_below ? base_below[row + ix] : (float)NAN;
				base_y = std::isnan(bb) ? (double)get_height(pos) : (double)bb;
			} else {
				base_y = plane_y;
			}
			const double value = add ? amp : (base_y + amp);
			if (batched) {
				vals[row + ix] = (float)value;
			} else {
				_stamp_write(wlayer, p_layer_id, composite, wloc, wregion, pos, value, blend);
			}
		}
	}

	if (batched) {
		_apply_stamp_block(wlayer, (int)std::lround(min_x / vs), (int)std::lround(min_z / vs), gw, gh, vals.data(), blend);
	}
}

// ---- Closed-loop control/texture paint (Pasture3DSplat) ----
void Pasture3DData::stamp_splat_loop(const int p_layer_id, const PackedVector2Array &p_poly, const AABB &p_clip, const Dictionary &p_params, const PackedFloat32Array &p_lut) {
	if (p_poly.size() < 3) {
		return;
	}
	const double min_x = p_params.get("min_x", 0.0);
	const double min_z = p_params.get("min_z", 0.0);
	const double vs = p_params.get("vs", 1.0);
	const int gw = (int)p_params.get("gw", 0);
	const int gh = (int)p_params.get("gh", 0);
	if (gw < 1 || gh < 1) {
		return;
	}

	// Field: GPU analytic when the box is large enough + a local RD exists, else the C++ chamfer (Plow/Splat
	// ignore max_inside; they normalise on falloff_width). Same 3-tier fallback as Mound (spec §4).
	std::vector<float> field;
	{
		bool got_field = false;
		const int threshold = _gpu_raster_threshold();
		if (threshold > 0 && (gw * gh) >= threshold) {
			Pasture3DGPURaster *gpu = _ensure_gpu_raster();
			if (gpu) {
				float mi_unused = 0.f;
				got_field = gpu->closed_loop_field(p_poly, min_x, min_z, vs, gw, gh, field, mi_unused);
			}
		}
		if (!got_field) {
			raster_sdf(p_poly, min_x, min_z, vs, gw, gh, field);
		}
	}

	const double strength = p_params.get("strength", 1.0);
	const double edge_offset = p_params.get("edge_offset", 0.0);
	const double falloff_width = p_params.get("falloff_width", 0.0);
	const int material = (int)p_params.get("material", 0);
	const bool preserve_base = p_params.get("preserve_base", true);
	const uint32_t uv_bits = (uint32_t)(int64_t)p_params.get("uv_bits", 0);
	const bool composite = p_params.get("composite", true);
	const double noise_strength = p_params.get("noise_strength", 0.0);
	Object *noise_obj = p_params.get("noise", Variant());
	Ref<FastNoiseLite> noise = Object::cast_to<FastNoiseLite>(noise_obj);

	const double ramp_denom = MAX(falloff_width, 0.001);

	// Phase 1d batched control apply: accumulate per-cell control words into a box buffer (+ skip mask),
	// then commit one tile at a time. Used for the deferred non-base TYPE_CONTROL overlay; otherwise the
	// per-cell set_control_on_layer path (full-refresh, region-map fallback, or base target).
	Pasture3DLayer *wlayer = _layer_stack.is_null() ? nullptr : _layer_stack->get_layer_ptr(p_layer_id);
	const bool batched = wlayer && wlayer->get_map_type() == TYPE_CONTROL && !composite && !wlayer->is_base();
	std::vector<uint32_t> cvals;
	std::vector<uint8_t> cmask;
	if (batched) {
		cvals.assign((size_t)gw * gh, 0u);
		cmask.assign((size_t)gw * gh, 0);
	}

	const bool has_clip = p_clip.size != Vector3();
	const double cx0 = p_clip.position.x;
	const double cx1 = p_clip.position.x + p_clip.size.x;
	const double cz0 = p_clip.position.z;
	const double cz1 = p_clip.position.z + p_clip.size.z;

	for (int iz = 0; iz < gh; iz++) {
		const double z = min_z + iz * vs;
		if (has_clip && (z < cz0 || z >= cz1)) {
			continue;
		}
		const int row = iz * gw;
		for (int ix = 0; ix < gw; ix++) {
			const double signed_d = (double)field[row + ix] + edge_offset;
			if (signed_d <= 0.0) {
				continue;
			}
			const double x = min_x + ix * vs;
			if (has_clip && (x < cx0 || x >= cx1)) {
				continue;
			}
			double t = (double)raster_ramp(p_lut, (float)(signed_d / ramp_denom)) * strength;
			if (noise.is_valid()) {
				t += noise_strength * noise->get_noise_2d(x, z);
			}
			t = CLAMP(t, 0.0, 1.0);
			const int blend_int = (int)std::lround(t * 255.0);
			if (blend_int <= 0) {
				continue;
			}
			const Vector3 pos(x, 0.0, z);
			const uint32_t cur = get_control(pos);
			const uint8_t base_id = preserve_base ? get_base(cur) : (uint8_t)material;
			const uint32_t ctrl = enc_base(base_id) | enc_overlay((uint8_t)material) | enc_blend((uint8_t)blend_int) | uv_bits | (cur & 0x6);
			if (batched) {
				cvals[row + ix] = ctrl;
				cmask[row + ix] = 1;
			} else {
				set_control_on_layer(p_layer_id, pos, (int)ctrl, 1.0, composite);
			}
		}
	}

	if (batched) {
		_apply_control_block(wlayer, (int)std::lround(min_x / vs), (int)std::lround(min_z / vs), gw, gh, cvals.data(), cmask.data());
	}
}
