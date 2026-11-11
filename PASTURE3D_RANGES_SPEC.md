# Pasture3D Ranges Spec — hills and mountain ranges from lines and areas

Status: written 2026-11-11. Step 1 (Path Range) built 2026-11-11, uncommitted; steps 2–4 unbuilt. Check the code before trusting this header.

## Goal

Build the terrain behind the Milos cliffs without drawing every hill. Today a range is either one Ridge
brush per crest (one spline, one cross-section, no spurs) or a Mountain Range Radial (branches from a single
point). The island nodes showed the better pattern: give the system an AREA and let it generate the
features, then hand-draw only the key ones.

Four steps, in this order. Each one is useful alone and each one is the input the next step builds on.

| Step | What | Kind | Feeds |
|---|---|---|---|
| 1 | **Path Range** — a crest line becomes a whole range: varied peaks, spurs both sides, valleys between | Generator over a PATH, C++ op 76 | erosion, step 4 |
| 2 | **Slope** — slope (and aspect) as a field and a band mask | Mask, C++ op 77 | scatter, colour, erosion masks |
| 3 | **Generate Range Splines** — a closed outline becomes a set of crest paths inside it | GRID+PATH → PATH SET | step 1 |
| 4 | **Salève Uplift mode** — an uplift field grows a fully drained ridge-and-valley landscape | Mode on an existing solver | the whole hinterland |

Every new node follows `new-node-checklist`: spec §13 and the acceleration guide; one C++ kernel with a
sixteen-slot `*_params_from(P, 16)` shared by the binding and the op; `graph_op_ids()` row; `_inputs()` /
`_outputs()` APPEND only; registry entry; a gate where every criterion has a control that fails, plus
compiled-vs-GDScript parity; port goldens re-recorded. Reuse, never re-derive: `Pasture3DPathGeom` for
point-to-path queries, `distance_transform_solve` / `distance_transform_nearest` for JFA distances,
`box_mean_solve` for windows, `fractal_grid` for noise, `wang_hash` for seeded choices,
`Pasture3DThreadPool` for threading. All distances are world metres, never cells.

---

## Step 1 — Path Range (op 76, Generators)

**Built 2026-11-11** (src/pasture_3d_path_range.{h,cpp}, gate bench/GraphPathRangeGate). Two departures from
the text below, both found by the gate:
- A line is evaluated as the MAX over its segments of each segment's clamped-projection profile, not at the
  single nearest point. A line's height varies along it, so the nearest point jumps across a bend's medial
  axis and stepped the height (a 58 m cliff on a wandering spur). Within a line the max is hard; blend_k
  merges between lines. Consequence: an open end reads the crest's upper envelope (up to ~18 m above the
  taper formula at defaults), never below it by more than the 31 m resampling chord.
- Pasture3DPathGeom::nearest returns segment -1 (distance 0) past its index rings; no longer used here, but
  any caller rasterising wider than the path's own bounds must check `segment < 0`.

### What it computes

Input: a crest PATH (open; a closed path is treated as a ring range) and an optional base HEIGHT to add to.

1. **Crest profile.** Along arc length `s`, crest height
   `hc(s) = peak_height · taper(s) · (1 + peak_variation · n1(s / peak_spacing))`
   where `n1` is seeded 1D fBm in world metres and `taper` eases to `end_height` over `end_taper` metres at
   each open end. If the path carries `heights` (a draped or hand-set spline), `use_path_heights` multiplies
   them in instead of `peak_height`, so a drawn crest keeps its authored peaks.
2. **Spurs.** Every `spur_spacing` metres (jittered ±50 %, seeded per index with `wang_hash`), a spur leaves
   the crest on alternating sides (`alternate`, or seeded random side). Direction = crest normal rotated by
   `spur_angle` ± `spur_angle_jitter` back along the crest (spurs rake downhill like real interfluves).
   Length = `spur_length` · (0.6 + 0.8·rand) · (hc / peak_height) — taller peaks throw longer spurs. Each
   spur is a short polyline (bent by `spur_wander` via the same 1D noise), whose own height runs from the
   crest height at its root to the foot height at its tip along `spur_profile`.
   `spur_levels` (0–2) repeats this once more off each spur at half the spacing, length and height.
3. **Height field.** For every cell, each ridge line (crest and every spur) contributes
   `h_line(s) · xsec(d / half_width(s))`, `half_width = width_ratio · h_line` so steepness is constant
   across sizes, and `xsec` the shared ridge cross-section (`crest_shape`: ROUND / SHARP / FLAT, the same
   profiles Path Carve uses). The field is the soft max of all contributions (`blend_k` metres), so spurs
   merge into the crest without a seam and valleys form between spurs on their own.
4. **Detail.** Optional `detail` amplitude of `fractal_grid` (RIDGED style, world metres) scaled by the
   local range height, so detail dies out at the foot.
5. Result = `input + field` (ADD) or `max(input, field)` (MAX), per `blend`.

Spur geometry is generated once per evaluation in C++ from the crest, deterministic in `seed`; distances
come from `Pasture3DPathGeom` over the crest and the generated spurs (one index, all lines).

### Inputs

`path` (PATH, required), `height` (HEIGHT, unwired 0; the base), `amount` (MASK, aux, unwired 1; scales the
range, e.g. Shore Character's inland distance so ranges fade toward the coast), value ports for
`peak_height`, `seed`.

### Outputs (APPEND only)

`height` (HEIGHT), `crest` (MASK: 1 on crest and spur lines, falling over their half-width), `valley`
(MASK: low between spurs, `1 - field/h_local` inside the range footprint), `footprint` (MASK: inside the
range's foot).

### Parameters (16 slots)

peak_height 300 m, peak_spacing 600 m, peak_variation 0.5, end_taper 400 m, end_height 0.2 (fraction),
width_ratio 2.5, crest_shape ROUND, spur_spacing 250 m, spur_length 500 m, spur_angle 25°,
spur_angle_jitter 15°, spur_wander 0.3, spur_levels 1, blend_k 40 m, detail 0.15, seed, plus the blend
mode and `use_path_heights`. That is 18; fold `blend` and `use_path_heights` and `crest_shape` into one
packed int slot, documented in `path_range_params_from`.

### Gate: GraphPathRangeGate

- PA crest heights follow `hc(s)`: sampled on the crest they match the formula within 1e-3. Control: a
  different seed differs by > 10 %.
- PB spurs exist and alternate: on a straight crest, cross-sections at spur roots rise on alternating sides.
  Control: `spur_spacing` past the crest length gives no spurs (field is the bare crest).
- PC no seam: the largest neighbour step in height is below `tan(atan(1/width_ratio)) · cell · 1.5`
  everywhere. Control: `blend_k` 0 (hard max) shows a crease larger than the soft one.
- PD world-metre invariance: 64² vs 128² agree at shared points within 2 % of peak_height. Control: a
  half-scaled `spur_spacing` differs by more.
- PE `amount` scales: wired 0.5 halves the field. Control: unwired equals all-1.
- PF compiled route == GDScript route (`force_gdscript_evaluation`) for every output; thread parity on a
  ≥ 128-row grid (`thread-parity-needs-128-rows`).

---

## Step 2 — Slope (op 77, Masks)

### What it computes

Metric gradient by central differences in world metres (the same formula `recast_cliff_solve` uses
internally — factor it out of `pasture_3d_terrain_metrics.cpp` as `slope_solve` and make Recast Cliff call
it, so there is one slope in the codebase), optionally pre-smoothed by `box_mean_solve` at `scale` metres so
a slope can be asked "at the scale of a hillside" rather than of a cell.

### Outputs (APPEND only)

`degrees` (FIELD, 0–90), `mask` (MASK: smoothstep band `min_angle..max_angle` with `falloff` degrees each
side), `aspect` (FIELD, 0–360°, compass direction the slope faces; flat reads 0).

`degrees` and `aspect` are raw measurements, so they follow `solver-outputs-are-metres`; `mask` is the
selector itself and is the one exception, because a Slope node whose only use is a band would otherwise
always be followed by a Float to Mask. Port 0 is `degrees` (FIELD), so the standard mask is not added.

### Parameters

min_angle 30°, max_angle 90°, falloff 5°, scale 0 m (raw). 

### Gate: GraphSlopeGate

- SA a plane tilted 20° reads 20° ± 0.05 everywhere and aspect equal to its dip direction ± 0.5°.
  Control: the same plane at 64² and 128² reads the same (a per-cell slope would not).
- SB band mask: on a cone, mask is 1 inside the band and 0 outside it beyond `falloff`. Control: widening
  the band raises the masked area.
- SC `scale` smooths: noise-on-plane at scale 50 m reads within 2° of the plane. Control: scale 0 does not.
- SD Recast Cliff output is bit-identical before and after the refactor (hash pinned before).
- SE compiled == GDScript; op in `graph_op_ids()`.

---

## Step 3 — Generate Range Splines (PATH domain)

### Why it needs a path SET first

A PATH port carries ONE polyline (`Pasture3DGraphPath`; `path_from_flow` states the limit and points at
`PASTURE3D_SPLINE_GRAPH_SPEC.md` §12.3). A range system is a tree. So step 3 starts by adding parts:

- `Pasture3DGraphPath.part_starts: PackedInt32Array` — the vertex index each part starts at. Empty means
  one part, so every existing path, scene and golden is unchanged.
- The shared query (`nearest`, the uniform index, and the C++ `Pasture3DPathGeom`) builds segments
  **within** parts only. Path Distance, Path Mask, Path Carve, Coast Profile and Path Range then handle a
  set with no code of their own.
- Every per-vertex PATH node (Resample, Smooth, Decimate, Fractalize, Meanderize, Drape, Width) is
  audited and either loops per part or warns "uses part 0 only" in `node_warnings()`. No silent joins:
  the audit table goes in this spec when step 3 starts, and the gate checks each listed node.
- The viewport overlay draws each part separately.

### What it computes

Input: a closed outline PATH (the island's Path Fractalize output) and an optional HEIGHT (the coast
profile). Output: a PATH SET of crest lines inside the outline, each with `heights` set so Path Range's
`use_path_heights` gives taller ranges deeper inland.

Modes:
- **SPINE** — the medial axis. Rasterise the outline, `distance_transform_solve` INSIDE, trace the ridge of
  the distance field (cells that are local maxima across their gradient), prune branches shorter than
  `min_branch` metres, smooth. Gives one or more spines that follow the island's shape, like a horseshoe
  island's hills following its arms.
- **FOLDS** — `count` parallel crests at `angle`, spaced `spacing`, bent by `wander` noise, clipped to the
  outline inset by `coast_inset`. Fold-belt ranges.
- **SCATTER** — `count` short ridges (`length` ± jitter) at seeded positions inside the inset outline,
  oriented by `angle` ± `angle_jitter`, rejected if closer than `spacing`. Volcanic and rolling hill
  country (Milos).

Shared parameters: `coast_inset` (metres kept clear of the shore, measured by the inside distance),
`seed`, and `height_from_depth` (crest heights = `peak_height · ss(depth / depth_scale)`).

GDScript is allowed here (`path-nodes-carved-out-of-step-0`) but the medial-axis trace runs on a grid and
should call a C++ helper alongside `distance_transform_nearest`; decide when building whether the trace is
worth native code (measure only with the user's go-ahead).

### Gate: GraphRangeSplinesGate

- RA SPINE on a rectangle gives one crest along its long axis within one cell; on an L shape, a crest per
  arm. Control: a disc gives no long spine (pruned to nothing or a point).
- RB every vertex of every part lies at least `coast_inset` inside the outline. Control: inset 0 lets
  vertices reach the shore.
- RC parts do not join: Path Distance between two parallel FOLDS crests reads the true gap midway, not 0.
  Control: the same points as one part (part_starts emptied) read near 0 across the joining segment.
- RD each audited per-vertex node keeps the part count, or warns. Control: a node marked "part 0 only"
  is listed in `node_warnings()`.
- RE determinism: same seed, same set (hash). Control: another seed differs.

---

## Step 4 — Salève Uplift mode

### Why this comes back

`pasture_3d_erosion.h` records "no uplift term: Pasture3D authors its big shapes with brushes", and
Salève's Stage 1 header records why the free steady state was removed: it rebuilt the terrain from
distance to the outlets and ignored the input (r 0.970 against inputs at 0.188). Both were right for a
solver whose job is to erode an authored shape. They are wrong for the job the island nodes revealed:
generating a whole area from a mask. That job wants exactly the free steady state, driven by an **uplift
field** instead of the input height.

So this is a second Stage 1 mode, not a new solver: same drainage graph, same control-point lattice, same
Stages 2 and 3, same outlets.

### What it computes

`stage1_mode`: INPUT (today, default, bit-identical) or UPLIFT.

In UPLIFT, each vertex rises from its receiver by the stream-power steady state
`z_i = z_r + (U_i / (K · A_i^m))^(1/n) · d_ir`, clamped by the existing `max_slope` wall,
with `U` the new `uplift` input (MASK 0..1, times `uplift_height`), `A` the drainage area already
accumulated, and outlets where they are today (sea / low ground of the input). The input HEIGHT still
decides routing order and outlets, so the sea and coast from Coast Profile stay the base level. Result =
max(input, steady state) inside the uplift footprint, so coasts and beaches are untouched.

What it gives: feed it the island's inside distance (or Path Range's footprint, or a painted mask) and the
whole hinterland comes out as dendritic valleys and interfluves that actually drain to the sea — the
large-area generation the island nodes made feel natural. Path Range then becomes the way to put a
specific range where you want it, and Uplift fills everything around it.

### Inputs and parameters

New port appended to Salève: `uplift` (MASK, unwired 0 — unwired means INPUT mode behaves exactly as
today). New params `stage1_mode`, `uplift_height` (m, default 300), `uplift_n` (slope exponent, 1).
Salève takes its params from a Dictionary, not the sixteen slots; append keys, do not reorder.

### Gate: extend GraphHydraulicSaleveGate (or a new GraphSaleveUpliftGate)

- UA INPUT mode is bit-identical to the pinned hashes. Control: UPLIFT mode differs.
- UB heights scale with uplift: doubling `uplift_height` scales the steady-state relief by `2^(1/n)`
  within 2 %. Control: INPUT mode does not move.
- UC follows the mask: a ring-shaped uplift gives a ring-shaped range (mean height inside the ring > 3×
  outside). Control: a uniform uplift does not.
- UD drains: every land cell reaches an outlet by its receivers (no pits after Stage 2). Control: the
  raw uplift field has pits.
- UE resolution invariance on a field metric (`resolution-invariance-needs-field-metric`), not a scalar
  mean.
- UF the 100 000 control-point cap and spacing behaviour unchanged (`saleve-point-cap`).

---

## Milos wiring once built

```
Path Fractalize (outline) ─┬─ Coast Profile A ─ Wave Exposure ─ Shore Character ─ Coast Profile B
                           ├─ Generate Range Splines (SCATTER) ─ Path Range ─┐
                           └─ inside distance ─ uplift ───────────────────────┴─ Salève (UPLIFT) ─ Coastal Erosion
Slope ─ mask ─ scree / colour
```

Coast Profile B is the base level; Path Range places the southwest peak and the main hills; Uplift fills
the rest with drained valleys; Coastal Erosion and Islet Scatter finish the shore.

## Open questions for the user

1. Step 3 SPINE and SCATTER first, FOLDS later? Milos needs SCATTER; FOLDS suits other islands.
2. Should Path Range also output its spurs as a PATH SET (for roads along ridges, or a Path Carve per
   spur)? Cheap once step 3 exists; out of scope for step 1.
3. Performance: none of these has a budget yet. Each gets measured only when you say so.
