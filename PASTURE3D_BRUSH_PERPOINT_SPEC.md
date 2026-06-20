# Pasture3D Brush Performance — Per-Moved-Point Dirty Box (Option D, future round)

Status: **spec only, not scheduled.** Banked as its own future round (after the Round 3 compositing
work). This is the highest-ceiling remaining optimisation for the common action "nudge one point of a
big feature", because it shrinks the **box itself** — cutting clear + paint + composite **together** —
rather than the per-cell cost. But it is the most correctness-delicate, hence deferred.

## The idea

Today a single point move re-bakes the whole changed spline's footprint (`prev∪curr`, tile-snapped). For
a 384×384 m mound that is ~150 k cells through clear + rasterise + composite even though only the cells
near the moved point actually changed. Per-point shrinks the dirty box to the **moved point's
neighbourhood** instead of the whole spline footprint:

`dirty = (prev_pos ∪ new_pos of the moved control point)` expanded by:
- the brush lateral reach (`_padding()`), and
- enough arc to cover the **two baked segments adjacent** to the moved point (moving a vertex moves its
  two incident edges),
then tile-snapped as today. Re-bake only that box. Cells outside it keep their existing layer samples.

Detecting the moved point is already half-built: `_curve_cache` (added in Round 1 for snap) holds each
spline's last-baked point positions; diff to find the moved index/indices (and union their
neighbourhoods for multi-point drags). Industry precedent: MicroVerse caches and only re-converts the
changed spline; this goes one level finer to the changed *point*.

## Why it's hard (closed-loop SDF)

The Mound/Plow/Splat SDF and the dome normalisation are **global properties of the whole loop**, so a
naive sub-grid breaks:

- **`max_inside`** (dome denominator) is the max interior distance over the ENTIRE polygon. Computed from
  a sub-grid it would be wrong. → Cache the loop-wide `max_inside` from the last full bake and reuse it;
  only recompute on a full refresh.
- **SDF in the sub-grid.** The scanline inside/outside fill works per-row over the full polygon regardless
  of grid extent (cheap for a few rows). But the **chamfer distance transform** seeds from the
  inside/outside boundary; a sub-grid deep in the interior (far from any edge) has no seed inside it, so
  its distances would be wrong. The moved point IS on the boundary, so the box around it contains the
  boundary and is locally correct — but cells in the box far from the boundary need correct distances
  too. Options: (a) seed the sub-grid borders with the cached full-bake distance values (a "boundary
  condition" so the chamfer continues correctly); (b) accept that only near-boundary cells change and
  bound the box tightly enough that interior cells are negligible; (c) keep a cached full-resolution SDF
  and patch only the changed region. (a)/(c) are the correct-but-complex paths.

Open polylines (Ridge/Trough) are easier: the lateral-distance field is local to the polyline, and the
moved point only affects cells near its two segments. `along`/`total_length` (end taper) is global but
recomputable cheaply, or cache per-segment arc offsets. So Ridge/Trough per-point could ship before the
closed-loop case.

## Sketch

- Detect moved point(s) via `_curve_cache` diff (already present).
- `dirty_point = neighbourhood(prev_pos, new_pos, padding, adjacent-segment arc)`, tile-snapped.
- Reuse cached loop-wide `max_inside` (closed loop) / `total_length` (polyline); pass into the `stamp_*`
  call as params instead of recomputing.
- Clear + stamp + composite only `dirty_point`. Repaint overlapping layer-mates clipped to it (same
  overlap rule as Round 1 §3.2).
- Fall back to the current whole-spline dirty rect when: the point count changed (add/remove), a param
  changed, the node moved, or the moved-point neighbourhood can't be bounded reliably.

## Expected

For "nudge one point of a 384² mound": box ~384² → ~64² ⇒ ~30× fewer cells ⇒ clear + paint + composite
all drop ~30× (bake ~200 ms → ~10 ms). No effect when the whole feature genuinely changes (param edit,
resize) — those still take the full path.

## Why later, not now

Closed-loop SDF correctness (above) is the risk; Round 3's compositing win is simpler and benefits every
composite in the engine. Ship Round 3 first; revisit D if single-point edits on very large features are
still the pain point. The `stamp_*(clip)` hook and `_curve_cache` from Rounds 1–2 are the foundation, so
D is an extension, not a rewrite.
