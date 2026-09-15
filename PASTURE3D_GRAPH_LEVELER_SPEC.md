# Pasture3D Graph Leveler Node Spec

**Status: unbuilt (spec accepted 2026-09-14).** Check `Pasture3DGraphNodeLeveler` and `GRAPH_OP_LEVELER`
before planning from this header — spec status headers go stale.

A terrain-graph FILTER that levels a height field inside an area, either to a statistic of the terrain
already there (Flatten) or to an authored world height (Level at Height), and builds a feathered wall
outside the area back down/up to the untouched terrain.

Follows `PASTURE3D_NODE_ACCELERATION_GUIDE.md` end to end: production C++ node, `[Dev/GD]` oracle behind
the dev flag, parity gate, CPU multithreaded kernel, GPU plan. No part of the default configuration may
bail the GPU route (§3.5 of the guide — a bail is graph-wide).

---

## 1. Ports

### 1.1 Inputs

| # | Name | Type | Required | Meaning |
|---|---|---|---|---|
| 0 | `height` | HEIGHT | yes | Terrain to level, world metres. |
| 1 | `loop` | PATH | no | Closed path whose interior is the area. |
| 2 | `mask` | MASK | no | [0,1] area mask. |
| 3 | `target_height` | FLOAT | no | Overrides the inspector `target_height` when wired. Level at Height only. |

### 1.2 Outputs

Multi-output slots are contiguous from row 0, so port index == channel index.

| # | Name | Type | Meaning |
|---|---|---|---|
| 0 | `height` | HEIGHT | Leveled terrain. |
| 1 | `level_mask` | MASK | Final weight actually applied: 1 in the area, falling through the feather to 0. After cut/fill gating. |
| 2 | `level_value` | FLOAT | The resolved level `L` (§3). Level at Height: the target. Flatten: the statistic. |
| 3 | `delta` | HEIGHT | `out - in` per cell, signed metres. Negative = cut, positive = fill. |
| 4 | `walls` | MASK | The feather ring only, shaped per `walls_shape`, scaled by how far the cell moved (§4.3). |

---

## 2. Parameters

| Name | Type | Default | Notes |
|---|---|---|---|
| `mode` | enum | FLATTEN | `FLATTEN`, `LEVEL_AT_HEIGHT`. |
| `statistic` | enum | MEAN | `MEAN`, `MEDIAN`, `MIN`, `MAX`. Flatten only. |
| `target_height` | float (m, world Y) | 0.0 | Level at Height only; overridden by input 3. |
| `cut_fill` | enum | BOTH | `BOTH`, `CUT_ONLY` (only lower cells above L), `FILL_ONLY` (only raise cells below L). |
| `feather_side` | enum | INSIDE | `INSIDE` (wall within the area, §4.1a), `OUTSIDE` (wall beyond it). Added 2026-09-14: a brush can only write inside its own footprint, so an outward wall there has nowhere to go. Slot 10. |
| `feather` | float (m) | 5.0 | Wall width, on the `feather_side` of the area boundary. 0 = hard edge. |
| `feather_from_path_width` | bool | false | Use the loop's own width as the feather distance (§4.2). |
| `path_width_scale` | float | 1.0 | Multiplier on the path width when the above is on. |
| `falloff` | Curve | smoothstep-like ease | Shapes the wall: x = 0 at area edge → 1 at feather edge, y = weight (1→0). Lowered as a 256-entry LUT like `Pasture3DGraphNodeCurve`. |
| `walls_shape` | enum | BAND | `BAND` (1 across the ring), `SLOPE` (proportional to the wall's steepness, §4.3). |
| `wall_depth` | float (m) | 1.0 | Cell movement at which `walls` reaches full strength. |
| `median_bins` | int | 4096 | Histogram resolution for MEDIAN. Advanced; hidden unless dev flag. |

---

## 3. Area resolution

1. **Core area `A`** (per cell, [0,1]):
   - `loop` wired and closed → interior by even-odd test (the `path_mask` closed rule, feather 0).
   - `loop` wired and OPEN → node warning "Leveler: loop must be a closed path — ignored", treated as unwired.
   - `mask` wired → mask value.
   - Both wired → product.
   - Neither → every finite cell (A = 1). A brush evaluates its graph with `p_mask = null` and
     composites through its own footprint, so the footprint is not a grid the node receives: cells
     outside it arrive as non-finite height. **A non-finite cell is outside the area and outside every
     statistic, always.** Inside a brush that rule IS the footprint; on a full terrain it is the grid.
   - A mask that is ≥ 1-1e-6 on every finite cell counts as unwired — the unwired default is 1, so the
     evaluator cannot tell the two apart and neither does the rule.
2. **Fully-inside set `I`** = cells with `A >= 1 - 1e-6` and finite height.
3. **Level `L`:**
   - `LEVEL_AT_HEIGHT`: `L = target_height` (input 3 if wired).
   - `FLATTEN`: statistic of `height` over `I`. Non-finite cells excluded, never clamped in.
     `MEDIAN` is the **lower median** (the order statistic at rank ⌈N/2⌉), estimated by a histogram over
     `[min_I, max_I]` with `median_bins` bins: rank k = N/2, the median bin is the first whose cumulative
     count reaches k, and the value is interpolated linearly within it. Error bound: one bin,
     `(max_I - min_I) / median_bins`, **against the lower median**. It is NOT bounded against the
     midpoint of the two middle values: on sparse data (few cells per bin) those two sit further apart
     than a bin, and measured on the oracle gate's fixture the gap was ~3 bins. The parity gate compares
     the kernel against the oracle's identical histogram, not an exact sort.
   - `I` empty (loop thinner than a cell, all-NaN, mask never reaches 1) → node warning, **height passes
     through unchanged**, `level_mask`/`delta`/`walls` are zero, `level_value` is NaN. CPU and GPU must
     decide this identically in one mirrored place.

---

## 4. Per-cell evaluation

### 4.1 Weight

`d` = outside distance (m) from the core area's boundary; `d = 0` inside.

- **Exact route** — a closed loop is wired AND the mask is trivial (§3.1): exact metric distance to
  the polygon boundary (`Pasture3DGraphPath.nearest` / `path_distance_grid_geom`).
- **Raster route** — anything else (a non-trivial mask, with or without a loop; or no loop): distance
  to the nearest core cell by the Distance Transform's JFA (`_field`, Euclidean, seed = core, JFA+1
  repair pass). Approximate by design, so CPU, GPU and oracle agree by construction.

`F` = feather distance at the cell (§4.2). Core cells: `w = 1`. Other cells:
`w = max(A, falloff(d / F))` when `F > 0 and d < F` (the ring), else `w = A`. So a soft mask keeps its
own value where it exceeds the wall, and `F == 0` is a hard edge (`w = A`). Cells with `w <= 0` are
untouched on every output.

The falloff is always a full 256-entry LUT — the unassigned default `1 - smoothstep(x)` is baked into it
too, so the kernel has no second definition — sampled by the `raster_ramp` rule
(`pasture_3d_brush_raster.cpp`): `f = x*(n-1)`, lerp between `lut[int(f)]` and the next entry.

### 4.1a Inward wall (`feather_side = INSIDE`, the default)

The edge is everything that is not the core: non-core cells (the loop's outside, a soft mask, non-finite
footprint cells) **and the grid border**. For a core cell, `d` = the nearest of:

- the exact polygon distance, when a closed loop is wired, the mask is trivial and **no cell is
  non-finite** (a footprint is an edge the polygon does not know about);
- otherwise the JFA distance to the nearest non-core cell (`_field(core, false)`, the Distance Transform's
  INSIDE; the no-seed fallback is the field diagonal);
- the border: `min((ix+1)dx, (gw-ix)dx, (iz+1)dz, (gh-iz)dz)`, the cell one past the grid, centre to centre.

Core cells with `F > 0 and d < F` are the ring: `t = 1 - d/F`, `w = falloff(t)`, so the LUT reads the same
way on both sides (x = 0 at the flat end, 1 at the untouched edge). Deeper core cells: `w = 1`. Non-core
cells: `w = A`. The statistic is still taken over the whole core `I`, band included. `walls` follows §4.3
with this `t`. **GPU:** the same plan as outward — the JFA is seeded from non-core cells (`DT_SEED` want 0),
`GKM_LEVELER_APPLY` takes `ip2` bit 4 and applies the border minimum, and the exact-route test counts
finite cells with `GKM_LEVELER_PREP` kind 5 (one extra readback, only with a loop and a trivial mask).

### 4.2 Feather from path width

When `feather_from_path_width` and a closed loop is wired: `F = path_width_scale * half_width(s)` where
`s` is the nearest boundary sample (the width at the nearest segment, interpolated along it) — so a wall
widens and narrows with the authored loop. The nearest-segment query already returns that segment; the
tie rule is the one fixed in [[nearest-segment-tie-order]]. With no loop wired the option is inert and
the inspector shows `feather` instead (property hint refresh via `notify_property_list_changed`).
The GPU path-distance kernel must output the interpolated width alongside distance (one extra channel in
the same dispatch) — not a second nearest-segment search.

### 4.3 Height, gating, walls

```
target  = lerp(h, L, w)
out     = CUT_ONLY  ? min(h, target)
        : FILL_ONLY ? max(h, target)
        : target
delta   = out - h
level_mask = (|delta| > 0 || cut_fill == BOTH) ? w : 0          # 0 where gating refused the cell
ring    = (d > 0 && d < F) ? 1 : 0
move    = clamp(|delta| / wall_depth, 0, 1)
walls   = ring * move * (BAND ? 1 : slope_term)
slope_term = |d falloff/dt| / max|d falloff/dt|   # derivative from the LUT, normalised to [0,1]
```

`SLOPE`: `slope_term = |lut[i0+1] - lut[i0]| / max_i |lut[i+1] - lut[i]|` for the LUT interval containing
`t` (0 for a flat LUT). The height difference enters through `move`, not here, so the wall's steepness is
counted once. `ring` is a non-core cell with `F > 0 and d < F`, and `walls` is written only where
`delta != 0`.

---

## 5. Performance: multithreading and GPU

### 5.1 CPU (native kernel)

All passes run on `Pasture3DThreadPool`, and results are **bit-identical at 1 thread and N threads**
(the pool contract: a region's result must not depend on chunking).

| Pass | Parallelism | Notes |
|---|---|---|
| Area / interior test | `parallel_for_rows` | Uses `path_mask_grid_geom` internals; path geometry indexed with the box-sized cell of [[path-index-cell-sized-by-box]]. |
| Distance / feather width | `parallel_for_rows` | Path distance per row; JFA pass already threaded. |
| Statistic reduction | `parallel_for_rows` with per-chunk partials | MEAN: per-chunk `(sum as double, count)`, folded in chunk-index order (deterministic regardless of chunk count — accumulate in fixed 64-row blocks, not per chunk, so the fold order is identical at 1 and N threads). MIN/MAX: per-chunk, fold. MEDIAN: pass A min/max, pass B per-chunk histograms (int64 counts) summed. |
| Apply | `parallel_for_rows` | Pointwise; writes all five outputs in one pass. |

MEAN accumulates in double; `L` is lowered to float32 only after the fold (see
[[graph-program-params-are-float32]]).

### 5.2 GPU (RenderingDevice plan)

Must stay on the GPU route for every mode in the default configuration. Plan, per the Contrast pattern
(guide §3.5, route 3):

1. **Area:** `GKM_PATH_MASK` (closed rule) and/or mask input multiply — existing dispatch.
2. **Distance + width:** `GKM_PATH_DISTANCE` extended with the nearest-segment half-width channel (loop),
   or the JFA plan (mask/footprint).
3. **Reduction (Flatten only):**
   - MIN/MAX: reuse modes 22/23 (per-workgroup shared-memory min/max, then fold), masked to `I`.
   - MEAN: new partial mode — per-workgroup `(sum, count)` into the scratch buffer, then fold. Sum in
     float32 per 64-cell workgroup, fold with Kahan compensation; the parity tolerance accounts for it.
   - MEDIAN: min/max pass (22/23), then a histogram pass writing counts into a `median_bins` storage
     buffer (per-workgroup local histograms folded, or an atomic-free per-invocation scatter into
     workgroup-owned bins), then a fold that walks the cumulative counts to the median bin.
   - All reduction modes sit ABOVE the bounds guard with identity sentinels, exclude non-finite cells,
     and mirror the CPU empty-set rule.
4. **Apply:** one pointwise dispatch reading `L` from binding 3, falloff LUT from the LUT binding, writing
   height; the four extra outputs as extra channels (same dispatch count as the Erosion multi-output).

Level at Height skips pass 3 entirely (one fewer round of dispatches). Remember the MSVC 16380-byte literal
cap when growing `GRAPH_GRID_GLSL` — add a new chunk.

**As built (step 4, 2026-09-14)** — `GRAPH_OP_LEVELER` in `pasture_3d_graph_gpu.cpp`, `GRAPH_GRID_GLSL_4`.
Where it departs from the plan above, and why:

- **Height only.** The GPU plan holds one buffer per slot and refuses any program reading a channel above 0,
  so `level_mask` / `level_value` / `delta` / `walls` keep the CPU evaluator (as Path Carve's masks do).
- **No `GKM_PATH_DISTANCE` width channel.** The apply pass does its own brute-force nearest-segment scan
  and reads the half-width at that `s` through `pathHalfWidth`, so neither the shader nor the CPU needed a
  new channel. The closed-loop even-odd test is new (`GKM_LEVELER_AREA`) — Path Mask still refuses loops.
- **Reductions fold on the host.** `GKM_BLOCK_SUM` sums each 8x8 block on the GPU (a gather at the block
  origin, no shared memory); the host reads the block sums back and folds them in double. Counts are exact
  (≤ 2^24 cells, else the graph refuses). MIN/MAX reuse modes 22/23 and read two floats back.
- **Median by binary search, not a GPU histogram.** ~log2(bins) count passes, each counting core cells
  under a float32 cut chosen on the host so `h < cut` is exactly the kernel's double-precision `bin(h) <= b`.
  The median bin and its interpolation are therefore the CPU's, up to cells whose area membership differs
  in float32 at the loop boundary.
- **LUT rides in the geometry buffer** (appended after the five path stripes) — every binding is taken.
- **Staged plan with readbacks**, as driven parameters already do: core count (pass-through when 0), the
  trivial-mask min, then the statistic, then distance (JFA over the core indicator, or exact in the apply)
  and apply. Level at Height costs one readback; Median costs ~14.

Gate: `LevelerGpuGate` (windowed only; NO-SIGNAL headless).

### 5.3 Preview / Live

No special casing: `live_preview_resolution` downscales the grid; the statistic is computed on the
downscaled grid (a coarse mean differs from the full mean by sampling — acceptable for Live, bakes are
full-res). Feather and `wall_depth` are metric, so they do not rescale with preview resolution
([[saleve-measured-in-grid-fractions]]).

---

## 6. Build order

1. **`Pasture3DGraphNodeDevLeveler` ([Dev/GD] oracle).** Straight GDScript, exact math, same histogram
   median. Behind the dev flag.
2. **C++ CPU kernel** `leveler_grid` + `Pasture3DUtil` binding, threaded (§5.1). Production node
   `Pasture3DGraphNodeLeveler` fails fast if the kernel is missing.
3. **Register** in the palette AND `graph_op_ids()` — a missing op id silently drops the whole graph to
   GDScript ([[op-ids-omission-drops-graph-to-gdscript]]). Check `native_supported()` in the gate.
4. **Path-distance width channel** (GPU + CPU), then **GPU plan** (§5.2).
5. **Gates** (§7).

---

## 7. Gates — `LevelerGate`

Every criterion has a control that fails, and counts completions, not just the absence of failures.

| Id | Criterion | Control that must fail |
|---|---|---|
| A | Level at Height: interior cells equal target to 1e-4 m. | Target 0 with a fixture whose interior is already at 0 is NOT the fixture — use a sloped fixture. |
| B | Each statistic equals an independent CPU computation over `I` (not the node's own `evaluate()` — [[evaluate-is-not-an-oracle]]). | A statistic computed over `A > 0` (feather-weighted) must differ on the fixture. |
| C | Cut only never raises a cell; fill only never lowers one. | BOTH on the same fixture must do both. |
| D | Feather is outside: every cell with `d = 0` equals L; cells at `d >= F` equal input. | A centred feather implementation must fail A/D. |
| E | Path-width feather: wall width tracks a loop with varying widths (measure at two sites). | Constant feather fails. |
| F | Open loop → warning + pass-through; empty `I` → warning + pass-through, both routes. | |
| G | `walls` is zero where `|delta| == 0` and in the interior. | A ring mask without the movement scaling fails. |
| T | CPU 1 thread vs N threads bit-identical on a ≥ 512-row grid, asserting `parallel_dispatch_count` increased ([[thread-parity-needs-128-rows]]). | |
| P | Native vs Dev/GD oracle parity, all modes. | |
| GPU | GPU vs CPU parity for every statistic via a direct `graph_eval_grid_gpu` call; windowed only — headless reports NO-SIGNAL, not PASS ([[graph-gpu-bail-is-graph-wide]]). | A graph that bailed to CPU must be detected as a bail, not as parity. |

No performance benchmarks are run without asking first.

**As built (step 5, 2026-09-14).** Three gates, split by what they compare:

| Gate | Criteria | Run |
|---|---|---|
| `bench/LevelerGate.tscn` | A–G, plus H (non-finite height is outside the area and the statistic), each on the ORACLE, NATIVE and lowered GRAPH routes — the graph route with loop, mask and target by wire and `native_supported()` asserted | headless |
| `bench/LevelerNativeParityGate.tscn` | P (84 cases), T (512², dispatch count asserted), R (lowered graph vs oracle on all five channels) | headless |
| `bench/LevelerGpuGate.tscn` | GPU (height, 14 cases via direct `graph_eval_grid_gpu`), mask channels refused, empty core | windowed |

A–H run on every route because parity alone cannot catch a rule every route shares. Warnings are node
state, so the GRAPH route skips the warning half of F. `bench/LevelerBench.tscn` reports cost and is not a gate.

---

## 8. Out of scope

- Sloped/planar leveling (best-fit plane, level along a path's profile) — Path Drape / Road Grade cover
  profiles.
- Multiple loops per node — wire a merged mask.
- Using the loop's width for anything but the feather.
