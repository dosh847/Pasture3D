# Pasture3D Salève and Strata Fidelity Spec

**Status: T1–T3 built 2026-09-18 (`GraphStrataProfileGate`; T3's mask port deferred, see T3); S1 built 2026-09-18 (`GraphSaleveNetworkGate`); S2–S4 unbuilt.** Check the symbols named in each phase before planning from
this header — spec status headers go stale.

The graph's **Salève Hydraulic Erosion** (`Pasture3DGraphNodeHydraulicSaleve`, `src/pasture_3d_hydraulic_saleve.cpp`)
and **Strata** (`Pasture3DGraphNodeStrata`, `src/pasture_3d_strata.cpp`) nodes do not reach the fidelity of
their Hesiod counterparts. A line-by-line comparison against HighMap/Hesiod (`hmap::hydraulic_saleve`,
`DrainageBasin`, `hmap::gpu::strata` / `strata.cl`) found the gap is structural, not a matter of defaults.
This spec closes it in phases, Strata first (pointwise, cheap, high payoff), then Salève.

## 0. Ground rules

- **Licence.** HighMap and Hesiod are GPL; Pasture3D is MIT. Implement from the algorithm described here.
  Do not copy, translate or paraphrase their source line by line.
- **Units stay metric.** Everything in world metres or dimensionless slopes, as now. Hesiod works on a
  [0,1] field over a unit bbox; where this spec quotes a Hesiod parameter, the metric equivalent is given.
- **Every route changes together.** Strata has GDScript `eval_cell`, native `strata_grid` and a GPU twin
  (`pasture_3d_graph_gpu.cpp`, ~L1426). No phase lands with one route behind — a missing op bails the whole
  graph to CPU/GDScript (see `graph_op_ids`, `native_supported()`).
- **Lowering.** Every new `@export` is added to `native_lower()` and checked by diffing exports against the
  lowered params (Strata already lost `terrace_profile` once this way).
- **Gates.** Each criterion has a control that must fail (feature disabled / reverted), and counts
  completions, not just the absence of failures. Parse-check every edited GDScript before running.
- **Baselines.** Salève phases S2 and S3 change output by design. Re-record `GraphHydraulicSaleveGate`
  and `SaleveMarginInvarianceProbe` baselines at the end of the phase that moves them, never mid-debug.
- **Perf.** Do not run benchmarks without asking the user first.

---

## Strata

### Phase T1 — Profile and variable hardness

Problem: `pow(f, 1 + 15·hardness)` is `f^12` at the default hardness 0.75 — a flat shelf ending in a
one-pixel riser, which reads as a digital staircase. Hesiod's default (gamma 0.5) is the opposite shape:
a steep rise at the base of each band and a gentle tread above it.

1. Replace the power law with a **profile mode** enum:
   - `SHARP` (default): two linear segments. For gamma `g` in (0,1)∪(1,∞):
     knee `a = (1/g)^(1/(g-1))`, value at knee `b = g^(-g/(g-1))`;
     `u < a ? u·b/a : b + (1-b)(u-a)/(1-a)`. `g → 1` is the identity (guard |g-1| < 1e-3).
   - `SMOOTH`: `u^g · (1 - exp(-(50/g)·u))`.
   - `CURVE`: the existing `terrace_profile` LUT (unchanged behaviour when a curve is assigned).
2. `hardness` [0,1] remaps to gamma so existing scenes stay meaningful: `g = lerp(1.0, 0.15, hardness)`
   (0 = no benching, 1 = strong ledge). Document the mapping; do not expose gamma separately.
3. **Hardness variation**: new `hardness_variation` [0,1] (default 0.5).
   `g_local = clamp(g ^ (1 + hardness_variation · n(x,z)), 0.05, 10)` with `n` the same break noise
   field already sampled. Some beds ledge, others weather soft. A power rather than Hesiod's scale, so
   hardness 0 (g = 1) stays the identity under any variation.
4. **The tilt comes back off** (found while building T1): the output was `(q + profile)·bh`, which kept
   the dip tilt and break noise in the height — the dip tilted the ground itself. It is now
   `(q + profile)·bh − tilt`, as Hesiod does. Existing scenes with nonzero dip change height.
5. A Terrace Profile curve, when assigned, still overrides the built-in profile (no CURVE enum value),
   so saved scenes with a curve keep their look.

Gate `GraphStrataProfileGate`: profile endpoints (u=0→0, u=1→1) and monotonicity for a sweep of g in
both modes; the SHARP knee lands at `(a, b)` within 1e-5; CPU/native/GPU parity on a 128-row grid (the
thread pool runs serial below that). Control: variation 0 must produce a spatially constant g (asserted by
sampling the profile at two distant cells with identical in-band fraction).

### Phase T2 — Multiscale octaves

Problem: one pass gives one set of beds. Hesiod stacks the operation, which gives beds inside beds.

1. New `octaves` (int, 1–8, default 3) and `lacunarity` (default 2.0). Octave k uses
   `band_height_k = band_height / lacunarity^k`, applied to the **output of octave k-1**.
2. The lateral wander scales with each octave: shift_k = `tilt + break_amount · n / lacunarity^k`, so
   fine beds wander proportionally less than coarse ones. Dip tilt is shared by all octaves.
3. `octaves = 1` must reproduce T1 exactly (regression control).

Gate: octaves=1 bit-matches the T1 output; octaves=3 produces at least twice the risers of octaves=1 on
a linear ramp input; control: forcing lacunarity = 1 must fail the riser-count criterion. Parity across
routes as in T1. (Built: the original ≥ lacunarity² bound was wrong — a finer boundary that lands inside
a coarser riser merges with it, so hardness 1 gives 2 risers per base bed at 3 octaves, not 4.)

### Phase T3 — Where strata show: elevation and outcrop masks, mask port

Problem: our strata cover the input evenly. Hesiod limits them to elongated outcrops and fades them in
valleys.

1. **Elevation mask** (`elevation_mask` bool, default on; `elevation_mask_gamma` default 1.0):
   `t_e = pow(clamp((h - lo) / (hi - lo), 0, 1), gamma)`, with `lo/hi` from new `mask_low`/`mask_high`
   in **metres** (default 0 / 0 = auto from the input grid's min/max). Auto is extent-dependent, the same
   hazard as Salève's `reference_relief`; say so in the tooltip and let the user pin it.
2. **Outcrop mask** (`outcrop_mask` bool, default on): a Voronoi F2−F1 field evaluated in a frame rotated
   to the strike direction plus `outcrop_angle_shift` (default 45°), stretched by `outcrop_size`
   (metres, along-strike and across-strike, default 180 × 60), with the break noise added to the
   along-strike coordinate. `clamp(v, clamp_min, 1)` then reversed-remap to [remap_min, 1]
   (defaults 0.5, 0.6). Voronoi must be the same hash on CPU and GPU; reuse the graph's existing cellular
   implementation if one exists, else add a shared one.
3. Final blend: `out = lerp(in, strata, amount · t_e · t_o · mask)`.
4. New input port `mask` (MASK, unwired default 1.0) appended **last** so existing wiring keeps its port
   indices; update `native_param_ports()`.

Gate: with both masks off and mask unwired, output bit-matches T2 (control); with the elevation mask on,
change at the input minimum is 0 and at the maximum equals the unmasked change; the outcrop mask produces
cells with zero change and cells with full change on a 256² ramp. Route parity.

**As built (2026-09-18), and where it departs from the above:**
- **No auto range.** `mask_low` / `mask_high` are plain metres (defaults 0 / 100). An auto range needs
  the grid's min/max, which the per-cell `eval_cell` cannot see, and it is the extent-dependent hazard
  this repo already paid for once.
- **The outcrop mask is smaller than Hesiod's.** Fixed 45° off the dip, fixed 3:1 stretch, break noise on
  the long axis. `outcrop_strength` (default 0.4) and `outcrop_size` (180 m) replace
  angle-shift / two sizes / clamp-min / remap-min — P[12..15] are the last four param slots, and the GPU
  push constants were already full. Factor = `1 − strength · clamp(F2 − F1, 0, 1)`; at strength 1 it
  does reach 0. The GPU fills it on the host with the same C++ function (`strata_outcrop`), in the
  extended noise buffer `[noise | outcrop | lo, hi]`, so no Voronoi runs in GLSL.
- **The elevation-mask flag rides P[8]** as bit 1 beside the profile mode (`StrataFlags`).
- **The `mask` port is NOT built.** The native program carries four field inputs per op (`in0..in3`);
  ports 4+ can drive scalar params but not grids. Strata's ports 1–5 are scalars, so a mask appended
  last (port 6) cannot reach native or GPU, and moving it to port 1 breaks saved wiring. Open: either
  widen the program to more field inputs, or add a port migration. Until then, mask a Strata node with a
  downstream Blend.
- Gate: `GraphStrataProfileGate` [G] (elevation window, control: mask off changes cells below Mask Low)
  and [H] (outcrop factor spans [0, 1] at strength 1). [E] parity runs at the defaults, so both masks
  are covered on all three routes.

---

## Salève Hydraulic Erosion

### Phase S1 — Correct drainage network (same grid, same look class)

Problems: pits are self-receivers that are not outlets, so the network fragments into inward basins;
processing order is a height sort that becomes invalid once pits are rerouted; routing noise is re-hashed
every iteration so the network never settles.

1. **Lake rerouting.** After computing receivers, find each cell's terminal (outlet or pit). For pits,
   run a shortest-path search (Dijkstra on 8-neighbour ground distance) outward from the border outlets;
   when the search first touches a pit's basin, reverse the receiver chain from the touched cell back to
   the pit so the basin drains to the neighbour the search came from. Every cell must reach a border
   outlet afterwards.
2. **Tree order.** Build children lists from receivers; produce a per-outlet traversal (outlet → leaves).
   Accumulation walks it leaves → outlet; response times and the height update walk outlet → leaves.
   Remove the per-iteration `std::sort`.
3. **Height update.** `z_i = z_outlet + uplift · (t_i − t_outlet)`, then limit against the receiver.
   Remove the unexplained `* 0.05f`; the slope scale is carried by the slope limit (S1.5) and the remap.
4. **Stable noise.** Hash on `(seed, cell, neighbour)` only — not the iteration.
5. **Radial slope limit.** New `max_slope_center` (default 6.0) and `max_slope_border` (default 0.0),
   `uniform_slope` bool. `s(r) = lerp(border, center, pulse(r))`, `pulse(r) = 1 − r²(3 − 2r)` for r<1,
   `r` = distance to the domain centre / the smaller domain side. Slopes are dimensionless (as now).
6. **Iterations.** Default 200, add `tolerance` (default 1e-3, mean |Δz| in unit elevation). Report the
   iteration count reached through the result dict for gates.
7. Delete the dead `fine_erosion_strength` and `sediment_strength` params. Default `erosion_strength`
   0.7, `bank_smoothing` 0.0.
8. Break flats before solving: add 1e-3 × relief of seeded low-frequency noise to the working copy only.

Gate `GraphSaleveNetworkGate`: every cell's receiver chain terminates at a border outlet (count cells
checked == n); input with an interior pit — control: disabling rerouting leaves ≥1 non-border terminal;
converges below tolerance before max iterations on the fixture (control: per-iteration noise re-enabled
must not converge in the same budget); drainage area at outlets sums to the domain area. Re-record the
Salève gate baselines at phase end.

**As built (S1):**
- Stage 1 walks an adjacency (neighbour lists + edge lengths), never the grid, so S2 swaps the graph only.
  `order` is the BFS outlet → leaves; `root_of` names each vertex's terminal.
- Rerouting: Dijkstra from every outlet, keyed (distance, index) so the result does not depend on heap
  internals (the GDScript oracle has its own heap and matches to 6e-6 m). The first settled vertex of an
  undrained basin has its chain to the pit reversed onto its Dijkstra predecessor.
- Slope cap is `s(r)·vref/zptp` in unit elevation per unit length, i.e. `s` is a true m/m gradient.
  `uniform_slope` is lowered as border = centre, so it needs no slot of its own.
- Flat breaking: value noise on a fixed **50 m world lattice** (not a grid fraction, so a margin does not
  move it), amplitude 1e-3 of the unit relief, working copy only.
- Convergence: mean |Δz| per pass < `tolerance` × the current z range. The result dict carries
  `iterations` and `cell_area`; `debug_network` adds `receivers` and `drainage_area`. `reroute_lakes`
  and `stable_noise` are dictionary-only gate hooks.
- **Beyond the spec:** `gain`, `gamma` and `mix_factor` were deleted too. All 16 lowered slots were in
  use; slots 10–12 now carry `tolerance`, `max_slope_center`, `max_slope_border`. Gain/gamma is the
  Contrast node's job and `mix_factor` duplicated `erosion_strength`. The node's cache key now includes
  dx, dy and mask (it hashed the surface only, so rewiring them served a stale solve).
- Baselines re-recorded: `GraphHydraulicSaleveGate` [C] now wants > 0.01 m (was 0.2 m; the one-line
  incision runs on a different Stage 1 surface and S3 deletes it); [E] tests post-smoothing instead of
  the deleted tonal pass. `SolverThreadParityGate` wants ≥ 4 splits (the gain pass is gone).
  `SaleveMarginInvarianceProbe` worst drift at 60 m margin: auto 26.1 m, pinned 25.4 m. The radial slope
  pulse is centred on the *solved* domain, so a margin moves it — S2's margin decision must cover it.

### Phase S2 — Coarse irregular solve, smooth reconstruction

Problem: full-resolution D8 gives thin pixel-scale zig-zag channels. Hesiod erodes ~15k jittered points
and reconstructs, which is where the broad valleys and absence of 45° bias come from.

1. New `control_points` (int, 500–100000, default 15000). Place one jittered point per cell of a
   √N × √N lattice over the rect (seeded), snap the outer ring to the rect boundary; sample input height
   bilinearly.
2. Triangulate with `Geometry2D::triangulate_delaunay` (C++). Adjacency = triangle edges, with true 2D
   edge lengths. Cell area per vertex = one third of adjacent triangle areas. S1's solver runs on this
   graph unchanged apart from the neighbour source (write S1 against an adjacency abstraction so this is
   a swap, not a rewrite).
3. Outlets = boundary vertices.
4. **Reconstruction** to the grid, `reconstruction` enum:
   - `LINEAR`: barycentric within the containing triangle.
   - `GRADIENT` (default): per-vertex gradients (area-weighted least squares over neighbours), then
     cubic Hermite-style blend within the triangle so the surface is C¹-ish across edges.
   Use a triangle walk or a coarse bucket grid for point location; never an O(n·triangles) scan.
5. **dx/dy become reconstruction warps**: grid sample position += (dx, dy) in metres, multiplied by a
   biquadratic edge fade so the domain hull is never left. When unwired and `default_warp` is on
   (default on), use seeded fBm with `warp_amount` (metres, default 2% of the smaller rect side) and
   `warp_size` (metres, default ¼ of the smaller side). Routing bias from dx/dy is removed.
6. Mask, `eroded_rock` and `sediment` outputs keep their meaning on the grid.
7. Margin invariance: control-point density must be defined per unit area (points per km²), with
   `control_points` the count at the reference footprint, or the margin reintroduces the grid-fraction
   bug (`saleve-measured-in-grid-fractions`). Decide and document in the phase; the Margin probe gates it.

Gate: reconstruction reproduces an analytic plane exactly and a paraboloid within tolerance (control:
nearest-vertex reconstruction must fail the paraboloid); no NaN; channel orientation histogram on a cone
fixture has no peaks at multiples of 45° beyond a threshold (control: S1 grid solver must exceed it);
`SaleveMarginInvarianceProbe` stays within its current bound. Re-record baselines.

### Phase S3 — Deposition and fine incision

1. **Deposition** (stage 2) becomes fill-then-blend: fill depressions (priority-flood, then a smoothing
   of the filled field over `deposition_radius`), blend filled vs. eroded by gradient magnitude so flat
   floors take the fill and slopes keep their shape, then `lerp` by `deposition_strength`. Radius stays in
   metres; default raised to 10% of the smaller rect side when set to 0 (auto).
2. **Fine incision** (stage 3) calls the existing native stream-log solver on the reconstructed grid
   (fresh flow on the current surface — never the stale S1 receivers), with talus 0.1, deposition radius
   and strength from stage 2, and the node mask. Delete the one-line approximation.
3. `sediment` output = positive change from stage 2 + stream-log deposition; `eroded_rock` = negative
   change across all stages.

Gate: deposition only raises (never lowers) cells, and is zero on a fixture with no depressions
(control); stage 3 output matches a direct stream-log call on the same input (route check — not the node
calling itself, assert against the solver called independently); sediment + eroded mass balance reported.

### Phase S4 — Tidy, docs, defaults

- Inspector groups rebuilt around the new parameters; tooltips carry units.
- Update `PASTURE3D_NODE_VOCABULARY.md` and the erosion node docs.
- Before/after renders of the fixture scenes for Strata and Salève attached to the PR.

## Out of scope

- Hesiod's `strata_cells`, `strata_plates` and `strata_terrace` variants (candidates for later nodes).
- A GPU route for Salève (the solver stays native CPU; tree traversals are sequential per outlet).
