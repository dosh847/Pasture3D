// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
//
// Path Carve — one cross-section, cut or raised along a PATH
// (PASTURE3D_SPLINE_GRAPH_SPEC.md §7.1, S3).
//
// ---- WHAT THIS IS, AND WHAT IT REPLACES ----
//
// Pasture3DRidge and Pasture3DTrough each carry their own rasteriser in pasture_3d_brush_raster.cpp
// (`stamp_ridge_line`, `stamp_trough_line`). They are the same mathematics twice: a lateral distance to a
// polyline, a reference height, a profile across the flank, and a drape onto the terrain. Where they
// differ they differ in ways that are parameters, not algorithms — a sign, a flat middle, an inverted
// profile — and where they AGREE they have already drifted, which is the usual fate of two copies of one
// rule.
//
// This is that rule, written once, as a graph node. §9 of the spec then rebuilds both brushes on top of
// it. Being a node rather than a stamp is what makes the difference visible: the carve reads a surface
// and returns one, so it can sit between erosion passes instead of only at the end of them.
//
// ---- IT IS NOT ROAD GRADE, AND THE DIFFERENCE IS NOT SIZE ----
//
// pasture_3d_road_grade.cpp solves a road: a designed vertical alignment sampled at its own spacing, a
// crown, a cut batter and a fill batter that differ, bridge suppression, junction skips. Every one of
// those exists because A ROAD'S HEIGHT IS A DESIGN DECISION and the design is authored elsewhere.
//
// A carve has no alignment. Its height is either drawn on the path (`follow_path_height`) or taken from
// the ground it sits on. That is the whole difference, and it is why this file is a fifth the size rather
// than a variant of that one.
//
// ---- THE TWO REFERENCES ----
//
// The single most important paragraph in the design, and the one both brushes learned the hard way:
//
//   The crest (or floor) sits at the path, or at the ground plus `offset`. The flank descends from there
//   TO THE ACTUAL TERRAIN SURFACE AT EVERY POINT. Two references, not one — a fixed-height crest over
//   sloping ground with a fixed-height skirt floats at one end and buries itself at the other.
//
// And the second, which is subtler and is what `ground_ref` is for: the ground reference UNDER THE CREST
// is interpolated from the terrain height at the PATH'S OWN VERTICES, not sampled per cell. A per-cell
// ground reference makes the crest height wobble with every bump the flank happens to cross, so a ridge
// over rough ground develops a scalloped top. The drape onto per-cell ground is what the profile does;
// the SHAPE is anchored to the vertex reference.

#ifndef PASTURE_3D_PATH_CARVE_H
#define PASTURE_3D_PATH_CARVE_H

#include "pasture_3d_path_query.h"

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rect2.hpp>

namespace godot {

// Which way the cross-section goes. Named rather than left to a signed `offset`, because the sign also
// decides the sensible default blend (MAX for a crest, MIN for a bed) and reads correctly in a warning.
enum PathCarveSection {
	PATH_CARVE_CREST = 0,
	PATH_CARVE_BED = 1,
};

// How the flank reaches the ground.
enum PathCarveFlank {
	PATH_CARVE_FIXED_WIDTH = 0, // spread over the full lateral reach, whatever the height difference
	PATH_CARVE_SLOPE_ANGLE = 1, // descend at `slope_angle` until it meets the terrain, capped by the reach
};

// Where the flank's lateral reach comes from.
enum PathCarveWidthSource {
	PATH_CARVE_WIDTH_PATH = 0, // the path's own per-vertex half-widths, times `width_scale`
	PATH_CARVE_WIDTH_CONST = 1, // `width` metres everywhere, ignoring what the path carries
};

// How the carved cross-section composites onto the incoming surface.
//
// There is no ADD, and its absence is deliberate rather than an omission: the cross-section is already
// draped onto the incoming surface, so the carved height IS the surface plus the carve's delta. An ADD
// would be byte-for-byte REPLACE, and offering it would imply a difference that cannot exist.
//
// MAX and MIN are not no-ops for the same reason they look like they might be. With `follow_path_height`
// on, a CREST whose drawn line runs BELOW the ground beside it has a negative height difference and would
// dig a trench where a ridge was asked for; MAX is what stops that, and MIN is its mirror for a BED whose
// line runs above the ground.
enum PathCarveBlend {
	PATH_CARVE_REPLACE = 0,
	PATH_CARVE_MAX = 1,
	PATH_CARVE_MIN = 2,
};

struct Pasture3DPathCarveParams {
	int cross_section = PATH_CARVE_CREST;
	double offset = 0.0; // metres above (CREST) or below (BED) the reference
	double flat_width = 0.0; // half-width of the flat top / floor; 0 = peaked crest or V-basin
	int flank_mode = PATH_CARVE_FIXED_WIDTH;
	double slope_angle = 30.0; // degrees, SLOPE_ANGLE only
	int width_source = PATH_CARVE_WIDTH_PATH;
	double width_scale = 1.0;
	double width = 25.0; // CONSTANT only
	bool follow_path_height = true;
	int blend = PATH_CARVE_MAX;
	double falloff = 10.0; // extra feather beyond the flank foot, metres
};

// The sixteen-slot parameter block, unpacked. Both routes into the kernel go through this — the
// Pasture3DUtil binding for Tier 2, and GRAPH_OP_PATH_CARVE's case for Tier 3 — so the slot order is
// defined exactly once. Two unpackers would agree until someone inserted a parameter, and the failure
// then is a carve reading `falloff` as a slope angle: plausible, silent, and wrong by a factor of nothing
// obvious.
//
// Takes a raw pointer and a count rather than a PackedFloat32Array, because the lowered evaluator holds
// its resolved parameters in a `float[16]` on the stack (a wire into a parameter port can override one,
// so the program's own array is not what an op should read).
Pasture3DPathCarveParams path_carve_params_from(const float *p_params, int p_count);

// Carve `p_geom` into `p_surface` and return five grids.
//
//   height — the composited surface. NaN in the input is "no data" and passes through untouched: a carve
//            must not invent ground where the terrain says there is none.
//   bed    — 1 on the flat top or floor. EMPTY BY CONSTRUCTION when `flat_width` is 0, because a peaked
//            crest has no flat part; that is correct and it is what the node warns about.
//   flank  — the descending band, carrying the profile's own value rather than a binary 1. A mask that
//            said only WHERE the flank is could not feather an erosion blend across it.
//   cut    — the carve's coverage where it LOWERED the surface, 0 elsewhere.
//   fill   — the carve's coverage where it RAISED it. Weighted rather than binary for the same reason as
//            `flank`, and split by the sign of the actual change rather than by `cross_section`, because
//            a crest over a hilltop fills at the middle and cuts at the flanks.
//
// `p_profile_lut` is a 0..1 ramp: index 0 is the FLAT EDGE and reads 1, the last index is the FLANK FOOT
// and reads 0. The caller always bakes a full LUT — a user Curve or the analytic cosine default — so this
// kernel has one path and its oracle reads the identical table. Never left empty to mean "default":
// `raster_ramp`'s own empty fallback is a smoothstep that RISES, which is this convention upside down.
//
// An EMPTY path returns the surface unchanged and all four masks at 0, which is §4.3's rule: an
// unresolved source is a normal state, and a carve that flattened the terrain while a spline was being
// renamed would read as a solver bug.
//
// Returns { ok: bool, height, bed, flank, cut, fill }; ok is false only for a degenerate grid.
Dictionary path_carve_grid_geom(const Pasture3DPathGeom &p_geom, const PackedFloat32Array &p_surface,
		int p_gw, int p_gh, const Rect2 &p_rect, const PackedFloat32Array &p_profile_lut,
		const Pasture3DPathCarveParams &p_params);

// The Pasture3DUtil entry point: this is the function above with a `build` in front of it, which is what
// keeps the Tier-2 route and the Tier-3 geometry table from being two implementations.
Dictionary path_carve_grid(const PackedVector2Array &p_points, const PackedFloat32Array &p_widths,
		const PackedFloat32Array &p_heights, bool p_closed, const PackedFloat32Array &p_surface, int p_gw,
		int p_gh, const Rect2 &p_rect, const PackedFloat32Array &p_profile_lut,
		const Pasture3DPathCarveParams &p_params);

} // namespace godot

#endif // PASTURE_3D_PATH_CARVE_H
