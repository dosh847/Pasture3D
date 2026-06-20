# Pasture3D Brush — Below-Layer Sampling Spec

Status: agreed 2026-06-20, branch `perf/compositing-round3`. Fixes brushes climbing each other (and the
partial-bake "chop a Refresh fixes"). Also subsumes Round-3 option **B** (drops the redundant pre-paint
composite).

## Problem

`relative_to_terrain` (Mound/Plow), `follow_spline_height=false` (Ridge/Trough) and `snap_to_surface`
read `get_height()` = the FULL composite (all layers, incl. the brush's OWN layer and layers ABOVE it).
So overlapping features sample each other's height as their "ground" and stack up (climb). The partial
bake sharpens this into a visible chop: a clipped repaint of an overlapping tool samples the *current*
base in-box while its out-of-box remainder holds the base from its last full bake → mismatch at the box
edge. A full Refresh recomputes everything against one base, so it looks correct.

## Fix: sample only layers BELOW the brush's own layer

A brush's base reference = composite of layers `[0, _layer_id)` (everything beneath its layer; excludes
its own layer AND all layers above). This:
- stops climbing of features above and on the same layer;
- removes the chop (the base no longer depends on the brush's own — cleared/repainted — layer, so in-box
  and out-of-box agree; same-layer overlaps all drape on the same below-base then blend);
- is independent of the clear, so the **pre-paint composite is no longer needed** (option B).

## C++ (Pasture3DData)

Refactor the Round-3 per-layer accumulation in `_composite_height_region` into a shared helper
`_accumulate_height(acc, region_loc, rect, layer_end)` that blends height layers `[0, layer_end)` into a
rect buffer (cached-tile + raw sub-rect reads). Then:

- `PackedFloat32Array composite_height_below(int below_layer_id, double min_x, double min_z, double vs,
  int gw, int gh)` — for each region the grid spans, accumulate layers `[0, below_layer_id)` into a
  `gw*gh` row-major buffer aligned to the brush grid (NaN where uncovered → caller treats as "no ground",
  same as today's get_height NaN). Used by the rasterisers.
- `real_t get_height_below(int below_layer_id, const Vector3 &pos)` — single-pixel composite of layers
  `[0, below_layer_id)` at `pos` (NaN if uncovered). Used by the moved-point snap (few points).

`_composite_height_region` calls `_accumulate_height(..., layer_count)` then writes back (unchanged
output). Control/color are unaffected (height-only concern).

## Rasterisers (stamp_*)

Each `stamp_*` gains a `PackedFloat32Array base_below` param (the brush-grid below-composite). Where it
currently reads `get_height(pos)` for `relative_to_terrain` / `follow_spline_height==false`, read
`base_below[row + ix]` instead. NaN (uncovered) → fall back to `get_height(pos)` or the node Y plane
(match current uncovered behaviour). The GDScript fallback rasterisers do the same via a passed array.

## GDScript orchestration

In `_refresh_owner_rect` (and `_refresh_owner`):
1. `clear_layer_in_area(clip_box, composite=false)` — drop tiles, **no composite** (base no longer read
   from the live map).
2. `base_below = terrain.data.composite_height_below(layer_id, grid…)` over the clip box / each spline
   grid (the brush layer is `_layer_id`; "below" = `[0, _layer_id)`).
3. Snap moved points using `get_height_below(layer_id, point)`.
4. Paint: pass `base_below` to each `stamp_*`.
5. `composite_area(clip_box)` once; `update_maps`.

Per-spline grids differ, so compute `base_below` per spline (its footprint grid) — one extra
below-composite per painted spline; cheap after Round 3, and it replaces the dropped pre-paint composite.

## Verification

- The reported scene: two overlapping Mounds on a MAX layer — moving a point must NOT chop the other;
  must match a full Refresh. Ridge/Trough crossing a Mound; Plow over a Mound; snap-to-surface across a
  feature (points sit on the ground beneath, not on the feature).
- Layer order matters: a brush on a lower layer must ignore a feature on a higher layer (and vice-versa
  it should still sit on lower features). Reorder layers and confirm.
- No climbing across repeated edits (the original snap-to-self / relative-to-self family).
- Perf: one composite per bake instead of two (B); re-run `log_bake_timing`.

## Risks

- **Uncovered (NaN) base** at terrain edges / where no lower layer covers — define the fallback
  explicitly (node Y plane, or live get_height) so edges don't read NaN into heights.
- **Layer index semantics** — `_layer_id` must be the brush's stack index; "below" is strictly `<`.
  Confirm the base layer is index 0 and overlays ascend.
- **Full-refresh grids** can be large (whole footprints); the below-composite there is bigger but still
  one composite. Acceptable; falls back to the same path.
