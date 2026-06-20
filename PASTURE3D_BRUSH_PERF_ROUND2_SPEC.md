# Pasture3D Brush Performance — Round 2 Spec: Native C++ Rasteriser

Status: design agreed 2026-06-20, branch `perf/brush-rasterization-round2`. Goal chosen: **(b) port the
spline rasterisation to C++**, phased — **Phase 1 raw speed (sync C++)** now, **Phase 2 threading**
(non-blocking) only if a fast bake still hitches during live drag. GPU compute **(d)** is deferred to a
later experimental branch — see `PASTURE3D_BRUSH_GPU_RASTER_NOTES.md`.

## DONE — Phase 1 complete & verified 2026-06-20

All five brushes rasterise natively (`src/pasture_3d_brush_raster.cpp`): Mound/Plow/Splat (closed-loop
SDF) + Ridge/Trough (open polyline). Each GDScript `_paint_spline` shims to a `stamp_*` method on
`Pasture3DData` when present, keeping the GDScript loop as fallback + A/B oracle (`force_gdscript_raster`
export toggles it). Profiles are baked to LUTs so C++ matches `_ramp`/`_cross`. A `_stamp_write` helper
resolves the layer once + caches the region across same-region cells (the direct-write fast path).

**Measured `paint` speedups (native vs GDScript, same scene):** Mound 5.2× (284→54 ms, 3 tools/384²),
Ridge 7.6× (56→7 ms), Trough 9.5× (38→4 ms), Plow 5× (181→36 ms), Splat 4.3× (5.6→1.3 ms). Big-mound
total ~870 ms (round 1) → ~205 ms. **`paint` is no longer the bottleneck on any brush** — clear +
composite (compositing the box area, twice: base read + result) now dominate; that is native C++ already
and a separate subsystem (candidate "Round 3").

**Phase 2 (threading): NOT pursued** — sync bakes feel fine; revisit only if live-drag hitches.
**Splat caveat:** uses `set_control_on_layer` per cell (not the direct-write path); fast enough, and its
visual A/B wasn't fully exercised (no terrain material set up at test time) — re-verify coverage once
textures are configured.

## 0. Why

Round 1 (merged to `main`) made the dirty-rect bake cheap on compositing: common edits 84 ms → 24 ms.
But profiling exposed a new bottleneck — the **GDScript rasterisation itself**. A big 448×384 m mound
edit is ~870 ms, of which **~730 ms is `paint`**: the SDF/chamfer + per-cell loop, run in interpreted
GDScript over ~170 k cells × the overlapping tools. Compositing is now a small bucket everywhere.

GDScript is ~15–40× slower than native for tight numeric loops, so porting the same algorithm to C++ is
expected to bring that 730 ms to ~**20–50 ms** with **no architecture change** (layers stay CPU Images
that feed collision + save) and **no GPU/threading complexity**. The research playbook (MicroVerse:
230 ms → 12 ms) also relies on caching the changed spline (our Stage 1 §3) + bounds culling (our clip
box) — both already in place; round 2 just moves the math off the slow path.

## 1. What stays (Round 1 orchestration, unchanged)

All of `_refresh_owner_rect`'s orchestration stays in GDScript and keeps working as-is:
- per-spline dirty-rect trigger + `prev∪curr` footprint, tile-snapped `clip_box`;
- `clear_layer_in_area` (tile-bounded composite → base for `get_height`);
- moved-point surface snap; overlap-correct repaint of layer-mates; `_defer_composite` + one
  `composite_area`; `update_maps(type,false,false)`; edited-flag reset; footprint/curve caches;
  shared-curve warning; `log_bake_timing`.

Round 2 replaces ONLY the innermost work: each subclass `_paint_spline` (the field build + per-cell
loop + `_paint_*` writes). Everything around it is untouched.

## 2. The two archetypes to port

| Brush | Geometry | Field helper | Writes |
|---|---|---|---|
| Mound | closed loop | `_signed_distance_field` (scanline fill + 2× chamfer) | height (set/add, blend) |
| Plow  | closed loop | `_signed_distance_field` | height |
| Splat | closed loop | `_signed_distance_field` | control (uint32) |
| Ridge | open polyline | `_polyline_field` (seed + `_chamfer_payload`) | height |
| Trough| open polyline | `_polyline_field` | height |

So: **2 shared field builders** + **5 per-cell profile/value loops**. Color is unused by these brushes.

## 3. C++ API (Phase 1 — synchronous)

Add to `Pasture3DData` (it already owns the region images + layer stack, so the rasteriser has native
`get_height` and `layer->set_sample` access — no per-cell GDScript⇄C++ boundary). All writes are
**deferred** (no per-pixel composite): the GDScript orchestration calls `composite_area(clip_box)` once
afterwards, exactly as today.

Proposed entry points (one per subclass for a faithful 1:1 port; the two field builders are shared
internal helpers `_layer_sdf(...)` / `_layer_polyline_field(...)`):

```
stamp_mound_loop(layer_id, PackedVector2Array poly_world, AABB clip, Dictionary params, PackedFloat32Array falloff_lut)
stamp_plow_loop (layer_id, PackedVector2Array poly_world, AABB clip, Dictionary params, PackedFloat32Array falloff_lut)
stamp_splat_loop(layer_id, PackedVector2Array poly_world, AABB clip, Dictionary params)
stamp_ridge_line (layer_id, PackedVector3Array pts_world, AABB clip, Dictionary params, PackedFloat32Array profile_lut)
stamp_trough_line(layer_id, PackedVector3Array pts_world, AABB clip, Dictionary params, PackedFloat32Array profile_lut)
```

- **Geometry** is passed already world-space + decimated to ~`vertex_spacing` (GDScript keeps
  `_polygon_xz` / `_baked_world_points` + `_decimate`; cheap, runs once per spline).
- **`params`** Dictionary carries the scalar knobs (height, capped, blend_mode, falloff_width,
  edge_offset, invert, relative_to_terrain, width, crest_height, taper_ends, noise_strength, control
  value, etc.). One Dictionary read per spline — negligible.
- **Curve LUTs**: GDScript bakes `falloff_curve` / `profile` to a `PackedFloat32Array(N=256)` via
  `sample_baked`; empty array ⇒ C++ uses the analytic default (`smoothstep` / rounded cosine). Avoids
  per-cell calls back into `Curve` and is thread-safe for Phase 2.
- **Noise**: pass the `FastNoiseLite` Ref in `params`; C++ calls `get_noise_2d` natively per cell (or
  bake to a small tile if Phase 2 thread-safety needs it).
- **`clip`** is the tile-snapped `clip_box`; the rasteriser only writes cells whose centre is inside it
  (max-edge exclusive, matching `_clip_contains`).
- **`get_height`** for `relative_to_terrain` / `follow_spline_height` is read natively inside the loop
  (correct base, since the clear composited the box first).

The bound methods get `DEFVAL`s so old call sites/builds degrade gracefully; see §5 fallback.

## 4. GDScript changes

Each subclass `_paint_spline` becomes a thin shim:
1. Build the world polygon/polyline (existing helpers) + the params Dictionary + baked LUT.
2. If `terrain.data.has_method("stamp_mound_loop")` → call the C++ rasteriser (passing `_layer_id`,
   `clip = _clip_aabb`, deferred). Else → run the existing GDScript loop (kept verbatim as the fallback
   and A/B reference).

`_paint_height/_control/_color` stay for the fallback path. `_defer_composite`/`_clip_aabb` semantics
are unchanged; the C++ path honours the clip and writes deferred (no composite) just like the GDScript
path with `_defer_composite=true`.

Port the shared base helpers' math to C++ once (`_signed_distance_field`, `_chamfer`, `_polyline_field`,
`_chamfer_payload`); keep the GDScript versions for the fallback.

## 5. Correctness & verification

- **A/B reference:** keep the GDScript rasteriser as the fallback so we can diff C++ vs GDScript output
  on the same scene. Target: visually identical; ideally bit-comparable layer samples (allow tiny FP
  differences from `real_t`/`float` and LUT quantisation — set LUT N high enough, or sample the Curve
  natively if exactness matters).
- **Preserve Round-1 invariants:** clip max-edge exclusive (ADD-safe), deferred writes, snap reads base,
  overlap-correct (each overlapping tool's C++ stamp clipped to the box).
- **Measure with `log_bake_timing`:** expect `paint` to collapse (730 ms → tens of ms); re-run the three
  scenarios from round 1 (small mound, big mound, mound + 2 loops) + an ADD-blend mound + a Splat.
- **Build:** `python -m SCons platform=windows target=editor` (libpasture .dll is gitignored; the editor
  loads GDExtension at startup, so a **full editor restart** is required to pick up the rebuild — a
  script reload is not enough).
- Parse-check the GDScript shims headlessly before handing back (a single parse error kills the
  `class_name`; see project memory).

## 6. Phase 2 — threading (only if needed)

If the now-fast bake still hitches during continuous live drag, make the C++ rasteriser non-blocking:
- Split it into **compute** (pure: takes geometry + params + a **pre-sampled base-height grid** for the
  clip box, returns a sample buffer — no live `get_height`/`set_sample`) and **apply** (main thread:
  write samples + `composite_area` + `update_maps`).
- Main thread, after the clear, samples the base-height grid for the box (native, cheap) and dispatches
  the compute via `WorkerThreadPool`; latest-wins coalescing + a generation guard (per the round-1 spec
  §2.2). Apply on completion via `call_deferred`.
- Curve LUTs (not live `Curve`) and the pre-sampled height grid make the compute thread-safe.
- Decide Phase 2 only after measuring Phase 1; a ~30 ms sync bake may already feel fine.

## 7. Risks / watch-items

- **Duplicated math (C++ + GDScript fallback)** can drift. Mitigate: the fallback is the reference;
  keep both in sync or, once C++ is trusted, demote the GDScript loop to a clearly-marked reference.
- **Curve LUT quantisation** vs live `sample_baked` — use N≥256 or sample natively if a brush needs
  exactness.
- **`real_t` vs `float`** — match the existing region image precision (FORMAT_RF = 32-bit float).
- **Multi-region clip boxes** — the rasteriser writes by world position → region/pixel via the existing
  `_global_to_region_pixel`; spans regions transparently (same as `set_height_on_layer` today).
- **FastNoiseLite thread-safety** (Phase 2) — prefer baking noise to a tile if concurrent reads prove
  unsafe.
