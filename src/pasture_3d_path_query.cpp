// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "pasture_3d_path_query.h"

#include "pasture_3d_thread_pool.h"

#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <cmath>
#include <limits>

using namespace godot;

// ---- construction -----------------------------------------------------------------------------------

bool Pasture3DPathGeom::build(const PackedVector2Array &p_points, const PackedFloat32Array &p_widths,
		const PackedFloat32Array &p_heights) {
	px.clear();
	pz.clear();
	width.clear();
	height.clear();
	cum.clear();
	bucket_start.clear();
	bucket_items.clear();
	bw = bh = 0;
	max_ring = 0;
	cell = 0.0;

	const int n_pts = p_points.size();
	if (n_pts < 2) {
		return false;
	}
	px.resize(n_pts);
	pz.resize(n_pts);
	for (int i = 0; i < n_pts; i++) {
		const Vector2 v = p_points[i];
		px[i] = (float)v.x;
		pz[i] = (float)v.y;
	}
	width.resize(p_widths.size());
	for (int i = 0; i < p_widths.size(); i++) {
		width[i] = p_widths[i];
	}
	// Copied VERBATIM, empty included. Not resized to n_pts and not padded: an array shorter than the ring
	// is what a closed path hands over — path_close_ring repeats the first VERTEX and cannot know to repeat
	// its height too — and `height_at` clamps the index for exactly that case. Padding here would put the
	// decision in two places.
	height.resize(p_heights.size());
	for (int i = 0; i < p_heights.size(); i++) {
		height[i] = p_heights[i];
	}

	cum.resize(n_pts);
	cum[0] = 0.0;
	for (int i = 1; i < n_pts; i++) {
		const double dx = (double)px[i] - (double)px[i - 1];
		const double dz = (double)pz[i] - (double)pz[i - 1];
		cum[i] = cum[i - 1] + std::sqrt(dx * dx + dz * dz);
	}

	const int n_seg = segment_count();
	if (n_seg < PATH_INDEX_MIN_SEGMENTS) {
		return true; // no index: every query is brute force, exactly as the GDScript does
	}

	double min_x = px[0], max_x = px[0], min_z = pz[0], max_z = pz[0];
	for (int i = 1; i < n_pts; i++) {
		min_x = std::min(min_x, (double)px[i]);
		max_x = std::max(max_x, (double)px[i]);
		min_z = std::min(min_z, (double)pz[i]);
		max_z = std::max(max_z, (double)pz[i]);
	}

	// ---- THE CELL IS SIZED BY THE BOX, NOT BY THE SEGMENT ----
	//
	// This used to be `max(mean segment length, 0.5)`, which sounds right and is the wrong quantity. A
	// uniform grid's cost is not paid per segment, it is paid per RING: a query cell `d` metres from the
	// line walks `d / cell` shells before the stopping rule can fire, and visits O((d / cell)^2) buckets
	// doing it. So the segment length sets the cost of the queries FAR from the path, which is almost all
	// of them — the path covers a sliver of the terrain and every cell of it asks.
	//
	// A meandering river makes that vivid: Path Meanderize turns a 250-point line into 4000, the mean
	// segment falls to 13 cm, the floor pins `cell` at 0.5 m, and a query 150 m away walks 300 shells —
	// 90 000 bucket coordinates, for one cell of a 512x512 grid. Measured: 11.8 s at 128x128, and at 512
	// it does not finish. The old count was already quadratic in distance; the reshape family only made
	// the constant big enough to see.
	//
	// So size the cell the way a uniform grid is normally sized: about one segment per cell BY AREA,
	// which puts roughly sqrt(n_seg) cells across the box and bounds `max_ring` at that. Bucket occupancy
	// rises to a handful, which `resolve` pays linearly and once.
	const double extent = std::max(max_x - min_x, max_z - min_z);
	const int axis_cells = std::max(1, (int)std::floor(std::sqrt((double)n_seg)));
	cell = std::max(extent / (double)axis_cells, 1e-4);

	ox = min_x;
	oz = min_z;
	bw = (int)std::floor((max_x - min_x) / cell) + 1;
	bh = (int)std::floor((max_z - min_z) / cell) + 1;
	bw = std::max(bw, 1);
	bh = std::max(bh, 1);
	max_ring = (int)std::ceil(extent / cell) + 2;

	// CSR build: count, prefix-sum, fill. Two passes over the same bucket spans so the counting and the
	// filling cannot disagree about which buckets a segment covers.
	std::vector<int> counts((size_t)bw * (size_t)bh, 0);
	auto span = [&](int p_seg, int &r_gx0, int &r_gx1, int &r_gz0, int &r_gz1) {
		const double ax = px[p_seg], bx = px[p_seg + 1];
		const double az = pz[p_seg], bz = pz[p_seg + 1];
		r_gx0 = (int)std::floor((std::min(ax, bx) - ox) / cell);
		r_gx1 = (int)std::floor((std::max(ax, bx) - ox) / cell);
		r_gz0 = (int)std::floor((std::min(az, bz) - oz) / cell);
		r_gz1 = (int)std::floor((std::max(az, bz) - oz) / cell);
		r_gx0 = std::max(r_gx0, 0);
		r_gz0 = std::max(r_gz0, 0);
		r_gx1 = std::min(r_gx1, bw - 1);
		r_gz1 = std::min(r_gz1, bh - 1);
	};
	for (int si = 0; si < n_seg; si++) {
		int gx0, gx1, gz0, gz1;
		span(si, gx0, gx1, gz0, gz1);
		for (int gz = gz0; gz <= gz1; gz++) {
			for (int gx = gx0; gx <= gx1; gx++) {
				counts[(size_t)gz * (size_t)bw + (size_t)gx]++;
			}
		}
	}
	bucket_start.resize(counts.size() + 1);
	bucket_start[0] = 0;
	for (size_t i = 0; i < counts.size(); i++) {
		bucket_start[i + 1] = bucket_start[i] + counts[i];
	}
	bucket_items.resize((size_t)bucket_start.back());
	std::vector<int> cursor(bucket_start.begin(), bucket_start.end() - 1);
	for (int si = 0; si < n_seg; si++) {
		int gx0, gx1, gz0, gz1;
		span(si, gx0, gx1, gz0, gz1);
		for (int gz = gz0; gz <= gz1; gz++) {
			for (int gx = gx0; gx <= gx1; gx++) {
				bucket_items[(size_t)cursor[(size_t)gz * (size_t)bw + (size_t)gx]++] = si;
			}
		}
	}
	return true;
}

// ---- per-vertex interpolation ------------------------------------------------------------------------

int Pasture3DPathGeom::vertex_before(double p_s) const {
	const int last = (int)px.size() - 2;
	if (last < 0) {
		return 0;
	}
	for (int i = 0; i < (int)px.size() - 1; i++) {
		if (p_s <= cum[i + 1]) {
			return i;
		}
	}
	return last;
}

// The rule, written once. Both index clamps matter: a CLOSED ring is one vertex longer than the arrays
// built from the open point list, so the closing segment reads the last entry at both ends — which is the
// first vertex's value, because a closed ring's last point IS its first point.
double Pasture3DPathGeom::lerp_vertex(const std::vector<float> &p_v, double p_s) const {
	if (p_v.empty()) {
		return std::numeric_limits<double>::quiet_NaN();
	}
	if (p_v.size() == 1) {
		return p_v[0];
	}
	const int i = vertex_before(p_s);
	const int last = (int)p_v.size() - 1;
	const double a = p_v[(size_t)std::min(i, last)];
	const double b = p_v[(size_t)std::min(i + 1, last)];
	const double seg = cum[(size_t)(i + 1)] - cum[(size_t)i];
	const double f = seg <= 0.0 ? 0.0 : std::clamp((p_s - cum[(size_t)i]) / seg, 0.0, 1.0);
	return a + (b - a) * f;
}

double Pasture3DPathGeom::half_width_at(double p_s) const {
	// 1.0, not NaN: a path with no widths still has a meaningful `t` if you read it as signed metres.
	// This is the fallback `height_at` deliberately does NOT share.
	const double v = lerp_vertex(width, p_s);
	return std::isnan(v) ? 1.0 : v;
}

// Deliberately NOT `half_width_at`'s twin with a different fallback. The fallbacks differ in kind: a path
// with no widths still HAS a meaningful `t` if you read it as metres, so 1.0 is a usable answer. A path
// with no heights has no elevation at all, and any finite answer would be invented.
double Pasture3DPathGeom::height_at(double p_s) const {
	// No fallback at all — `lerp_vertex`'s NaN is exactly the answer wanted here.
	return lerp_vertex(height, p_s);
}

// ---- the query --------------------------------------------------------------------------------------

double Pasture3DPathGeom::segment_distance(int p_seg, double p_x, double p_z) const {
	const double ax = px[p_seg], az = pz[p_seg];
	const double abx = (double)px[p_seg + 1] - ax, abz = (double)pz[p_seg + 1] - az;
	const double len2 = abx * abx + abz * abz;
	const double f = len2 <= 0.0 ? 0.0 : std::clamp(((p_x - ax) * abx + (p_z - az) * abz) / len2, 0.0, 1.0);
	const double dx = p_x - (ax + abx * f);
	const double dz = p_z - (az + abz * f);
	return std::sqrt(dx * dx + dz * dz);
}

Pasture3DPathHit Pasture3DPathGeom::resolve(double p_x, double p_z, const int *p_cand, int p_count) const {
	Pasture3DPathHit hit;
	double best = INFINITY;
	int best_seg = -1;
	double best_f = 0.0;
	for (int k = 0; k < p_count; k++) {
		const int si = p_cand[k];
		const double ax = px[si], az = pz[si];
		const double abx = (double)px[si + 1] - ax, abz = (double)pz[si + 1] - az;
		const double len2 = abx * abx + abz * abz;
		const double f = len2 <= 0.0 ? 0.0
									 : std::clamp(((p_x - ax) * abx + (p_z - az) * abz) / len2, 0.0, 1.0);
		const double dx = p_x - (ax + abx * f);
		const double dz = p_z - (az + abz * f);
		const double d = std::sqrt(dx * dx + dz * dz);
		// ---- THE TIE RULE: on an exact tie, the LOWER SEGMENT INDEX wins ----
		//
		// Without the second clause the winner of a tie is whichever candidate the caller happened to
		// offer first, and the indexed query offers them in BUCKET order while `nearest_brute` offers
		// them in segment order. So the two disagreed on exactly the cells that are equidistant from two
		// segments — the diagonal bisector at every corner of a path, and the whole midline of a hairpin.
		//
		// `distance` is identical either way, which is what made it invisible: only `s` moves, and with
		// it the half-width read at that `s`, so a corridor MASK steps by the width difference on a
		// single cell while the distance field it came from is exact. The GPU query (P2d) found it,
		// because a per-pixel brute-force loop is a third candidate order.
		//
		// Comparing doubles for equality is right here and only here: a tie that is not bit-identical is
		// already decided by `<`, and this clause exists precisely for the one that is.
		if (d < best || (d == best && si < best_seg)) {
			best = d;
			best_seg = si;
			best_f = f;
		}
	}
	if (best_seg < 0) {
		return hit; // segment -1: an empty candidate set, which only an empty path can produce
	}
	hit.distance = best;
	hit.s = cum[best_seg] + (cum[best_seg + 1] - cum[best_seg]) * best_f;
	hit.segment = best_seg;

	// POSITIVE IS THE DRIVER'S RIGHT. On Godot's XZ plane with +Y up, the right of a heading (dx, dz) is
	// (-dz, dx), so the side is the sign of the 2D cross product of the heading with the offset. Spelled
	// out because this is exactly the step a fixture sharing the code's convention cannot catch being
	// inverted — see PASTURE3D_ROAD_SYSTEM_PROPOSAL.md on the sign convention.
	const double ax = px[best_seg], az = pz[best_seg];
	const double abx = (double)px[best_seg + 1] - ax, abz = (double)pz[best_seg + 1] - az;
	double signed_d = best;
	if (abx * abx + abz * abz > 0.0) {
		const double cross = abx * (p_z - az) - abz * (p_x - ax);
		signed_d = cross >= 0.0 ? best : -best;
	}
	hit.t = signed_d / std::max(half_width_at(hit.s), 0.0001);
	return hit;
}

bool Pasture3DPathGeom::inside(double p_x, double p_z) const {
	if (!closed || px.size() < 4) {
		return false;
	}
	// Half-open comparison on the y span: a vertex exactly level with the ray is counted once, not twice.
	// The classic point-in-polygon bug, and it shows up as single wrong cells in a straight line — which
	// reads as noise rather than as a rule error.
	const int n = (int)px.size() - 1;
	bool odd = false;
	for (int i = 0; i < n; i++) {
		const double ay = pz[i], by = pz[i + 1];
		if ((ay > p_z) != (by > p_z)) {
			const double dy = by - ay;
			if (dy != 0.0) {
				const double x_cross = (double)px[i] + (p_z - ay) / dy * ((double)px[i + 1] - (double)px[i]);
				if (p_x < x_cross) {
					odd = !odd;
				}
			}
		}
	}
	return odd;
}

Pasture3DPathHit Pasture3DPathGeom::nearest_brute(double p_x, double p_z) const {
	const int n = segment_count();
	if (n == 0) {
		return Pasture3DPathHit();
	}
	std::vector<int> all((size_t)n);
	for (int i = 0; i < n; i++) {
		all[(size_t)i] = i;
	}
	return resolve(p_x, p_z, all.data(), n);
}

Pasture3DPathHit Pasture3DPathGeom::nearest(double p_x, double p_z, std::vector<int> &r_scratch) const {
	const int n = segment_count();
	if (n == 0) {
		return Pasture3DPathHit();
	}
	if (bucket_items.empty()) {
		r_scratch.resize((size_t)n);
		for (int i = 0; i < n; i++) {
			r_scratch[(size_t)i] = i;
		}
		return resolve(p_x, p_z, r_scratch.data(), n);
	}

	r_scratch.clear();
	const int cx = (int)std::floor((p_x - ox) / cell);
	const int cz = (int)std::floor((p_z - oz) / cell);
	double best = INFINITY;
	// A segment sitting in a bucket `ring` rings out from the query cell is at least (ring - 1) * cell
	// away, so once best <= (ring - 1) * cell no unexamined bucket can hold anything nearer. Stopping one
	// ring later than that bound keeps the off-by-one on the safe side; see the header.
	//
	// ---- THE WALK STARTS AT THE GRID, NOT AT THE QUERY ----
	//
	// A query cell can sit far OUTSIDE the bucket grid: every cell of the terrain is asked, and the path
	// covers a fraction of it. Walking rings from such a cell spends the first `ring_min` shells visiting
	// nothing but out-of-bounds coordinates, and `best` stays INFINITY the whole way so the stopping rule
	// cannot fire — O(ring_min^2) of pure skipping, per cell, over the whole grid.
	//
	// That is a cliff, not a slope, because `cell` floors at 0.5 m: a path whose vertex count has been
	// multiplied (Path Meanderize's business) has short segments, so `cell` bottoms out, so `ring_min`
	// counts HALF-METRES to the path. A 250 m gap is 500 shells is 250 000 bucket coordinates, times a
	// 512x512 grid. That is the hang, and it is why the reshape family made a pre-existing cost visible.
	//
	// So: start at the first ring that can intersect the grid at all (its Chebyshev distance to the box),
	// and clamp each shell to the box instead of testing coordinates one at a time. Skipping the earlier
	// rings cannot change the answer -- by construction they contain no in-grid cell, so the old loop
	// examined nothing in them either.
	int ring_min = 0;
	ring_min = std::max(ring_min, -cx);
	ring_min = std::max(ring_min, cx - (bw - 1));
	ring_min = std::max(ring_min, -cz);
	ring_min = std::max(ring_min, cz - (bh - 1));
	for (int ring = ring_min; ring <= max_ring; ring++) {
		const int gz0 = std::max(cz - ring, 0);
		const int gz1 = std::min(cz + ring, bh - 1);
		const int gx0 = std::max(cx - ring, 0);
		const int gx1 = std::min(cx + ring, bw - 1);
		for (int gz = gz0; gz <= gz1; gz++) {
			for (int gx = gx0; gx <= gx1; gx++) {
				// Only this ring's own shell; the interior was collected on an earlier pass.
				if (ring > 0 && std::abs(gx - cx) != ring && std::abs(gz - cz) != ring) {
					continue;
				}
				const size_t b = (size_t)gz * (size_t)bw + (size_t)gx;
				for (int k = bucket_start[b]; k < bucket_start[b + 1]; k++) {
					const int si = bucket_items[(size_t)k];
					// NOT de-duplicated. A segment spanning two buckets is offered twice and `resolve`
					// measures it twice, which costs one extra distance and changes nothing: its tie rule
					// is "lowest segment index wins", so it is independent of both order and multiplicity
					// (that is the whole reason it is index-based -- see `resolve`).
					//
					// What was here was a linear scan of the candidate list, on the argument that the list
					// is a handful. It is a handful near the path and hundreds far from it, and the scan
					// is O(m^2) in exactly the case that was already the expensive one.
					r_scratch.push_back(si);
					best = std::min(best, segment_distance(si, p_x, p_z));
				}
			}
		}
		if (best <= (double)ring * cell) {
			break;
		}
	}
	return resolve(p_x, p_z, r_scratch.data(), (int)r_scratch.size());
}

// ---- the grid kernel --------------------------------------------------------------------------------

Dictionary godot::path_query_grid(const PackedVector2Array &p_points, const PackedFloat32Array &p_widths,
		int p_gw, int p_gh, const Rect2 &p_rect, double p_unreachable, double p_max_distance,
		const PackedFloat32Array &p_heights) {
	Pasture3DPathGeom geom;
	geom.build(p_points, p_widths, p_heights);
	return path_query_grid_geom(geom, p_gw, p_gh, p_rect, p_unreachable, p_max_distance);
}

Dictionary godot::path_query_grid_geom(const Pasture3DPathGeom &p_geom, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_unreachable, double p_max_distance) {
	Dictionary out;
	if (p_gw <= 0 || p_gh <= 0) {
		out["ok"] = false;
		return out;
	}
	const int n = p_gw * p_gh;
	PackedFloat32Array dist, s_out, t_out, h_out;
	dist.resize(n);
	s_out.resize(n);
	t_out.resize(n);
	h_out.resize(n);
	const float nan_v = std::numeric_limits<float>::quiet_NaN();

	if (p_geom.is_empty()) {
		// One fill, not a per-cell branch. An unresolved Road Source is a normal state and the whole grid
		// has the same answer. The fill is `unreachable`, NEVER 0 — 0 would mean every cell is on the road.
		const float far_v = (float)(p_max_distance > 0.0 ? std::min(p_unreachable, p_max_distance)
														 : p_unreachable);
		dist.fill(far_v);
		s_out.fill(0.0f);
		t_out.fill(0.0f);
		// NaN, not 0 and not `far_v`. s and t fill with 0 because they are meaningless-but-bounded on an
		// empty path; an elevation of 0 would read as sea level and an elevation of `unreachable` would
		// read as ten kilometres. Only NaN reads as the truth, which is that there is nothing to measure.
		h_out.fill(nan_v);
		out["ok"] = true;
		out["distance"] = dist;
		out["s"] = s_out;
		out["t"] = t_out;
		out["height"] = h_out;
		return out;
	}

	// Cell CENTRES over p_rect — graph_cell_to_world's convention and the GDScript node's.
	const double dx = p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = p_rect.size.y / (double)std::max(p_gh, 1);
	const double min_x = p_rect.position.x + 0.5 * dx;
	const double min_z = p_rect.position.y + 0.5 * dz;

	float *dist_w = dist.ptrw();
	float *s_w = s_out.ptrw();
	float *t_w = t_out.ptrw();
	float *h_w = h_out.ptrw();
	// Hoisted: `height_at` answers NaN for every cell of a heightless path, and asking it gw*gh times to
	// be told so costs a nearest-vertex walk per cell for a constant.
	const bool has_h = !p_geom.height.empty();

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		// One candidate buffer per chunk, reused across every cell in it: the query allocates nothing in
		// its inner loop, and the buffer is thread-local by construction rather than by a lock.
		std::vector<int> scratch;
		scratch.reserve(32);
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			const double wz = min_z + (double)iz * dz;
			for (int ix = 0; ix < p_gw; ix++) {
				const Pasture3DPathHit hit = p_geom.nearest(min_x + (double)ix * dx, wz, scratch);
				const int idx = row + ix;
				dist_w[idx] = (float)(p_max_distance > 0.0 ? std::min(hit.distance, p_max_distance)
														   : hit.distance);
				s_w[idx] = (float)hit.s;
				t_w[idx] = (float)hit.t;
				// Off the SAME hit. This is the whole argument for a fourth channel rather than a fifth
				// node: `s` is already solved here, and `height_at` is one interpolation on top of it,
				// where a separate node would re-run the nearest-segment search for every cell.
				h_w[idx] = has_h ? (float)p_geom.height_at(hit.s) : nan_v;
			}
		}
	});

	out["ok"] = true;
	out["distance"] = dist;
	out["s"] = s_out;
	out["t"] = t_out;
	out["height"] = h_out;
	return out;
}

// ---- the mask kernel --------------------------------------------------------------------------------

// Close the ring HERE, once, exactly as Pasture3DGraphPath._ensure does: the closing edge is a real
// segment for distance and for the winding test alike, and adding it at the boundary means no query below
// has to remember that a path can be closed. Three points is the minimum for an area — a two-point
// "closed" path is a line doubled back on itself, and closing it would only duplicate a segment.
PackedVector2Array godot::path_close_ring(const PackedVector2Array &p_points, bool p_closed) {
	if (!p_closed || p_points.size() < 3) {
		return p_points;
	}
	PackedVector2Array ring = p_points;
	ring.push_back(p_points[0]);
	return ring;
}

PackedFloat32Array godot::path_mask_grid(const PackedVector2Array &p_points,
		const PackedFloat32Array &p_widths, bool p_closed, int p_gw, int p_gh, const Rect2 &p_rect,
		double p_width_scale, double p_feather, bool p_invert) {
	PackedFloat32Array out;
	if (p_gw <= 0 || p_gh <= 0) {
		return out;
	}
	out.resize(p_gw * p_gh);

	Pasture3DPathGeom geom;
	geom.closed = p_closed && p_points.size() >= 3;
	geom.build(path_close_ring(p_points, p_closed), p_widths);
	return path_mask_grid_geom(geom, p_gw, p_gh, p_rect, p_width_scale, p_feather, p_invert);
}

PackedFloat32Array godot::path_mask_grid_geom(const Pasture3DPathGeom &p_geom, int p_gw, int p_gh,
		const Rect2 &p_rect, double p_width_scale, double p_feather, bool p_invert) {
	PackedFloat32Array out;
	if (p_gw <= 0 || p_gh <= 0) {
		return out;
	}
	out.resize(p_gw * p_gh);
	if (p_geom.is_empty()) {
		out.fill(p_invert ? 1.0f : 0.0f);
		return out;
	}

	const double dx = p_rect.size.x / (double)std::max(p_gw, 1);
	const double dz = p_rect.size.y / (double)std::max(p_gh, 1);
	const double min_x = p_rect.position.x + 0.5 * dx;
	const double min_z = p_rect.position.y + 0.5 * dz;
	float *w = out.ptrw();

	Pasture3DThreadPool::parallel_for_rows(p_gh, 16, [&](int z0, int z1) {
		std::vector<int> scratch;
		scratch.reserve(32);
		for (int iz = z0; iz < z1; iz++) {
			const int row = iz * p_gw;
			const double wz = min_z + (double)iz * dz;
			for (int ix = 0; ix < p_gw; ix++) {
				const double wx = min_x + (double)ix * dx;
				double m = 1.0;
				if (p_geom.closed) {
					// REGION. Inside is a flat 1; feathering inward as well would eat a small shape from
					// both sides and leave a region that never reaches full strength anywhere.
					if (!p_geom.inside(wx, wz)) {
						const double d = p_geom.nearest(wx, wz, scratch).distance;
						m = p_feather <= 0.0 ? 0.0 : std::clamp(1.0 - d / p_feather, 0.0, 1.0);
					}
				} else {
					// CORRIDOR. Back from `t` to metres via the half-width AT THIS s, so the feather is a
					// real distance wherever the road is wide and wherever it is narrow.
					const Pasture3DPathHit hit = p_geom.nearest(wx, wz, scratch);
					const double half = std::max(p_geom.half_width_at(hit.s) * p_width_scale, 1e-6);
					const double edge = hit.distance - half;
					if (edge > 0.0) {
						m = p_feather <= 0.0 ? 0.0 : std::clamp(1.0 - edge / p_feather, 0.0, 1.0);
					}
				}
				w[row + ix] = (float)(p_invert ? 1.0 - m : m);
			}
		}
	});
	return out;
}
