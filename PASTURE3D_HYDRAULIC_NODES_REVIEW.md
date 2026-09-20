# Hydraulic nodes review: Particle Hydraulic and ErosionHydraulic

**Status: Phase 2 complete, 2026-09-19.** All ten plan items are built, gated and committed on
`feat/hydraulic-metric-outlets-pipe`. Sections 1-4 below are the Phase 1 review as written, kept
unedited as the record of what was found and measured; **they describe the code as it was**, so read
section 0 first for what is now true. Section 5's plan is annotated with what actually shipped.

---

## 0. What shipped (Phase 2)

| Rank | Item | Commit | Default look |
|---|---|---|---|
| 1 | Particle parity: quad differences in double, spawn skip in the native solver | `0d449528` | changes (float noise, amplified) |
| 2 | Particle native freeze, full freeze key, exact seed | `43f5f072` | unchanged |
| 3 + 5 | Particle `units = METRIC` and a Beyer erosion radius | `675dca44` | unchanged (both opt-in) |
| 7 | Grid `edge_mode = OUTLETS` at a fixed `outlet_level` | `6841c0cf` | unchanged (opt-in) |
| 8 | Grid `model = PIPE` (Mei, Decaudin & Hu 2007) | `907fc394` | unchanged (opt-in) |
| 4 | Particle aux channels in metres, opt-in `deposit_at_death` | `40e99de0` | **ports renamed** |
| 6 | Grid aux channels in metres, opt-in `settle_at_end` | `d731ce6f` | **ports renamed** |
| 9 | Ridge deflection direction drawn per droplet | `5f45aaa2` | changes where `ridge_forcing > 0` |
| 10 | Benchmark split out of the gate; header docs corrected | `ddfa2ff3` | unchanged |
| — | Follow-up: the grid's `flow` compared against its own peak | `3675fd82` | unchanged |

### Defect disposition

D1 D2 → item 1. D4 D5 D6 → item 2. D3 → item 3. D7 D8 D9 → item 4. D10 D13 → item 6.
D11 → item 7. D12 → item 8. D14 D15 → item 10. **All fifteen closed.**

S1 confirmed and fixed (item 9). S4 confirmed: the GPU did keep the normalised outputs, and its
normalisation pass is now deleted. S5 confirmed as a real gap and closed with a 160-row
`parallel_dispatch_count` criterion. S2, S3 and S6 were not pursued; S2 and S3 are still open.

### Ports, as they now are

Both solvers output `height`, `eroded`, `deposited`, `flow` — four ports, all in metres or a physical
unit, none normalised. `eroded` and `deposited` are net against the **final** surface, so a deposit later
cut away shows in neither. The grid's `flow` is a contributing area in m² under MUSGRAVE and a mean
discharge in m³/s under PIPE; the particle's is droplet path length per unit area at unit density, in
metres. A mask comes from Float to Mask. The old `sediment` and `water_depth` ports are gone, not
deprecated.

### Where the plan was wrong

- **Item 4's `water_depth` was dropped, not rebuilt.** The plan said "in metres from the water volume".
  There is no water volume to read at the end of a droplet solve — the droplets are gone — so the channel
  would have been another fabricated number. Three honest channels beat four with a passenger.
- **Item 9's proving fixture was wrong in the plan.** "The handedness criterion on a symmetric cone"
  cannot work: a cone is radially symmetric, so a spiralling flow still erodes a radially symmetric field
  and leaves no trace on the average. Measured on a cone, the biased code reported **no bias at all** at
  forcing 0, 0.6 and 2.0. The fixture that works is a plane tilted in +x — whose gradient has no z
  component, so the added perpendicular is purely lateral — with a symmetric bump on the fall line; the
  measure is the signed centroid of the scar off the fall line, averaged over seeds because the chiral
  part is seed-independent and the droplet noise is not. That measurement: **−0.064, +0.057, +0.144,
  +0.267 cells** at forcing 0, 0.3, 0.6, 1.2. After the fix: −0.009, −0.042, −0.016, all inside the
  zero-forcing noise floor.
- **Item 3's invariance criterion was too weak to fail its own control.** A scalar mean-cut comparison
  read 0.287 for METRIC and 0.284 for the grid-units control — the control could not fail. It was
  replaced with box-averaged change *fields* at 128/256/512 and an RMS gap that must shrink. 64² turned
  out to be pre-asymptotic and was dropped.
- **Item 8's PIPE is not a drop-in for MUSGRAVE's parameters.** Its sediment capacity is on a different
  scale: at MUSGRAVE's defaults PIPE removed about 21 m from a 40 m mound. That is a units mismatch, not
  a bug, and the tooltip now says to try Kc 0.05-0.5.
- **Item 6 also had to re-baseline a tolerance nobody listed.** GraphHydraulicAccelerationGate [C] held
  all three channels to one absolute 0.01, which was sized for a 0..1 channel. It only surfaced outside
  headless, because [C] skips without a RenderingDevice.

### Gate state at the end

All green, non-headless: GraphHydraulicGridGate, GraphHydraulicParticleGate,
GraphHydraulicAccelerationGate, GraphGpuParityGate, SolverThreadParityGate,
GraphPaletteAndConstantsGate, GraphAuxChannelGate, GraphNativeFreezeGate.

*(Corrected. This section first said GraphAuxChannelGate `[E]` and GraphNativeFreezeGate `[K] dla` were
still red "and untouched by this work". They were fixed shortly afterwards, on a branch that is now
merged — both were defects in the criteria, not in DLA. Three further gate repairs followed and are
also on `main`: [K] holds output-caching solvers to the frozen output again, keyed on the node's own
`serve_time_properties()`; [E]'s control moved to `mountain_range_radial`, whose `angle` port no kernel
writes; and `[gap]` measures the float32 param truncation again — see below.)*

New: `GraphHydraulicBenchmark.tscn` holds the timing that used to live in the acceleration gate. It
asserts nothing and is run deliberately.

Every criterion added in Phase 2 was proved by breaking the mechanism it measures and watching it fail.
The breaks are named in each commit message.

### The float32 param gap is still open, and nearly went unnoticed

`native_lower()` returns a `PackedFloat32Array`, so a lowered node's params reach the kernel as float32
while `ErosionHydraulicParams` keeps doubles on purpose. That is unchanged by this work and remains a
real defect; widening the program's param storage touches every lowered node.

What Phase 2 did change is that the hydraulic nodes now round their own params through `_f32()` so their
two routes agree. That made GraphAuxChannelGate's `[gap]` criterion — which compared the node against
the program — read 0.000000, and a passing session read that zero as the defect being fixed. It was not:
both sides of the comparison had simply become float32. `[gap]` now takes its reference from a solve
called directly with the authored doubles, reads **0.060323 m** (the same figure first measured on
2026-09-07), and is bounded **below** as well as above, because zero is the signal that the program was
widened and must fail loudly rather than pass quietly.

---

## 1. Algorithm summaries (Phase 1 record; describes the code BEFORE Phase 2)

Written for the approval gate in `HYDRAULIC_NODES_REVIEW_PROMPT.md`. Measurements come from one headless
correctness probe (a scratch script, since deleted; no benchmarks were run). The fixture was a 256 m
square with a tilted, sinusoidal surface, gw = 64 and 128.

### 1.1 Particle Hydraulic (`src/pasture_3d_hydraulic_particle.cpp`)

It is a Beyer-2015-style droplet solver, simplified, and it runs in **grid-cell units**. `p_rect` is never read.

| Stage | What happens | Where |
|---|---|---|
| Spawn | Uniform LCG position in `[0, gw-1) x [0, gh-1)` cells. The native solver has no mask test and no finite test at spawn. | cpp:164-165 |
| Gradient | Bilinear gradient over the cell quad, in **metres per cell**. The subtraction is done in float32 (`(double)(h10 - h00)`). | cpp:201-202 |
| Ridge forcing | Adds `0.5 * rf * perp(grad)`. The rotation always has the same sign, so every droplet veers the same way. | cpp:205-210 |
| Direction | `dir = dir*inertia - grad*(1-inertia)`, normalised. Each step is exactly **1 cell** long. | cpp:213-227 |
| Uphill | Deposits `min(sed, dh)` bilinearly on the 4 corners, then **the droplet dies** and the rest of its sediment vanishes. | cpp:267-279 |
| Capacity | `max(-dh, min_slope) * speed * water * K`. `dh` is metres per one-cell step. | cpp:282 |
| Erode/deposit | Uses the 4 bilinear corners with no radius brush. `bedrock_gap` caps the cut relative to the **input** surface. | cpp:284-314 |
| Speed | `sqrt(v^2 - dh*g)`. Beyer uses `sqrt(v^2 + dh*g)` with `dh` negative downhill, so this is the same thing. | cpp:316 |
| Death | At lifetime end, or on leaving the grid, the carried sediment is **discarded**, so mass is not conserved. | cpp:173, 176 |
| Aux | `sediment` = gross deposited metres, counting deposits later re-eroded. `flow` = sum of `water*w`, a dimensionless visit count. `water_depth` = `max(water*0.05*w)`, a fabricated number of at most 0.05. | cpp:275-327 |

The solver is single-threaded and serial. There is no GPU path.

### 1.2 ErosionHydraulic (`src/pasture_3d_erosion_hydraulic.cpp`)

The header calls this a "hydrodynamic shallow-water solver". It is not a pipe model (Mei 2007) and it has
no velocity field. It is closest to **Musgrave 1989**: greedy routing on the water-surface difference over 4 neighbours.

| Stage | What happens | Where |
|---|---|---|
| Rain | Adds `rain_rate` metres to `water` and to `flow_accum` on every finite cell, every pass. | cpp:304-311 |
| Routing | Neighbours are 4-connected on `h + w`. The outflow is `min(0.6 w, 0.5 sum(diff))`, split in proportion to `diff`. | cpp:188-247 |
| Capacity | `K * eff_slope * sqrt(clamp(eff_slope*cell_dist, .05, 50)) * w * (log(1+10*flow_accum)+1) * 0.5` | cpp:213-216 |
| Erode/deposit | Moves `(cap - s) * speed * 0.4`, clamped to `0.4 * min_downhill_diff`. | cpp:219-232 |
| Evaporation | `w *= 1 - evap` after the gather. | cpp:292-294 |
| Scatter | Uses `parallel_scatter_rows`, which replays in raster order, so the result is bitwise independent of thread count. | cpp:313 |
| Output | `sediment` is the **suspended** load still in the water at the end. It is not deposition, and it is divided by its own max. `flow` is `flow_accum / max`. Both are 0..1. | cpp:321-349 |

The routing gives the grid edge **no outlets**: an edge cell simply has fewer neighbours, so water and
sediment cannot leave. A NaN cell acts as a wall, not an outlet. A GPU twin exists
(`src/shaders/graph_solver_hydraulic.glsl`) and is reached through `erosion_hydraulic_solve_best`.

---

## 2. Hesiod comparison

**Caveat:** I did not run Hesiod in this pass, because it is not in this repo and I did not install it. The
comparison below comes from Hesiod/HighMap's public documentation, their parameter names, and the papers they
cite. I read none of their code. Running both side by side is item P0 of the plan (section 5).

### 2.1 Particle

| Aspect | Hesiod `HydraulicParticle` (documented) | Ours |
|---|---|---|
| Particle count | Given as a **density per cell** or relative to the map size, so it is resolution-stable. | An absolute `droplet_count`, so density changes with resolution. |
| Capacity, erosion, deposition | `c_capacity`, `c_erosion`, `c_deposition` | `sediment_capacity`, `erosion_speed`, `deposition_speed` |
| Motion | Inertia plus a **drag** term; velocity is a real vector. | Inertia only; the step is 1 cell. |
| Evaporation | `evap_rate` | `evaporation_rate` |
| Bedrock | An optional **bedrock map** input. | A scalar `bedrock_gap` below the input surface. |
| Moisture | A **moisture map** input that weights spawning. | A mask that weights the cut. The native solver does not weight spawning. |
| Outputs | Erosion map and deposition map. | Height, gross deposition, a visit count, and a fake depth. |
| Post filtering | An optional smoothing pass after the solve. | None. |
| Ridge forcing | **I could not find this in Hesiod's documentation.** Our comment calls it "Hesiod Ridge Forcing"; treat that attribution as unverified. | Present. |

Papers: Beyer 2015 (the thesis on droplet erosion) is the base of both. Our erosion brush is 4 bilinear
corners. Beyer uses an erosion **radius** with weighted deposition, and without it you get the familiar
single-cell pitting.

### 2.2 Grid

Hesiod/HighMap offers several grid hydraulics. The documented ones include a **virtual-pipes** model after
Mei 2007 and Št'ava 2008, a Musgrave-style model, a stream/flow-accumulation model, and Beneš. Ours is
the Musgrave-style one without its thermal half. What we lack against a pipe model:

- Water velocity from pipe flux: capacity is `Kc * sin(slope) * |v|`, with a real `dt` and CFL.
- Sediment advection along velocity (a semi-Lagrangian step), not pushed in proportion to the water.
- Outflow at the boundary.
- Separate erosion and deposition output maps in metres.
- Per-cell hardness.

What we have and they may not: a bitwise thread-invariant CPU path, and a GPU twin that is parity-gated.

---

## 3. Defect list

### 3.1 Confirmed

| # | Node | Defect | Evidence |
|---|---|---|---|
| D1 | Particle | **The native solver and the GDScript oracle diverge at the default lifetime.** The native solver takes quad differences in float32 (`(double)(h10-h00)`, cpp:201-202, 252 and the bedrock terms at 301-304). The oracle takes them in 64-bit. Droplet chaos amplifies the difference. | 2000 droplets, lifetime 30, 64²: **max 1.99 m, mean 0.038 m**, with no mask at all. Gate [A2] only uses 500 droplets for 10 steps, so it never sees this. |
| D2 | Particle | **Spawn differs between the routes.** The oracle skips a droplet whose spawn cell is non-finite or has `mask <= 0.001` (dev .gd:239-242). The native solver skips neither, so a droplet born in a mask-0 region walks into the unmasked area and erodes it. | Code-confirmed. The half-zero-mask run was swamped by D1 (2.11 m), so this needs its own control after D1 is fixed. No gate wires a mask. |
| D3 | Particle | **`p_rect` is unused, so every length is in cells.** The step is 1 cell, slope is metres per cell, and lifetime is in cells. | At the same world size and the same droplet density per area, the mean cut is **1.35 m at 64² and 1.09 m at 128²**, and max `flow` is **40 vs 24**. |
| D4 | Particle | **No native freeze.** There is no `freeze_key_grid_ports`, so a FROZEN Particle node takes the **whole graph** to GDScript (`blocks_native`). | hydraulic_particle is absent from `FREEZE_OPS` in GraphNativeFreezeGate. |
| D5 | Particle | **The cache key is the surface alone** (`_surface_hash`, .gd:223). A change to the mask, or to a wired `droplets`/`erosion_speed`/`deposition_speed`, never stales a frozen solve. | Code: `solver_cache_key(gw, gh, [surface])`. |
| D6 | Particle | **The seed is lowered as float32** (`p[9] = float(seed)`). A seed above 2^24 is rounded, so the graph-native route and the node's own GDScript route (which passes an int) solve with different seeds. Seed 0 also becomes 1337 in the native solver but stays 0 in the oracle. | Code: .gd:119; cpp:146 vs dev .gd:217. |
| D7 | Particle | **`water_depth` is not metres.** It is `max(water * 0.05 * w)`, which is at most 0.05 whatever the terrain. | 0.0488 at 64² and 0.0493 at 128². |
| D8 | Particle | **`flow` is a unitless visit count** that scales with `droplet_count` and resolution. | See D3. |
| D9 | Particle | **`sediment` is gross, not final.** Deposits that are later eroded still count. Mass is also lost: when a droplet dies of lifetime, goes uphill, or leaves the grid, its carried sediment is dropped. | cpp:173-176, 279. This is the Salève `sediment` bug class. |
| D10 | Grid | **`sediment` is the suspended load, not deposition**, and it is normalised to 0..1 by its own max. `flow` is normalised the same way. This breaks rules 1 and 2. | cpp:321-349. The max is exactly 1.000 at both resolutions. |
| D11 | Grid | **No outlets.** Border cells cannot send water off-grid, so water and suspended sediment pool along the rim. NaN cells act as walls, not outlets (the Erosion node treats no-data as an outlet). | cpp:191. This is the same margin-lift class as Salève before `outlet_level`. |
| D12 | Grid | **Resolution-dependent.** `flow_accum` is metres of rain summed per cell, not an area. The `log(1+10*flow)` factor, the `0.4`/`0.6`/`0.5` factors per pass, and `cell_dist` inside `vel` all change with the cell size. | Mean cut is **4.16 m at 64² and 2.88 m at 128²** on the same world. |
| D13 | Grid | **End-of-solve suspended sediment is deleted**, so mass is not conserved. | cpp:321 onward: `sediment` is never deposited. |
| D14 | Both | **The docs don't match the ports.** Particle's header says MASK but the ports are FIELD. The grid header says "shallow-water". | .gd headers. |
| D15 | Gates | **GraphHydraulicAccelerationGate [D] is a performance benchmark** inside a correctness gate. Under the standing rule it cannot run unasked, so the gate can't be run whole. | Gate :193. |

### 3.2 Suspicions (not measured)

- **S1: ridge forcing is a biased rotation, not dendritic organisation.** Every droplet turns the same way, so
  it should skew valleys sideways instead of branching them. To measure it: the mean flow-direction
  handedness on a symmetric cone, at rf = 0 vs 1.
- **S2: CONFIRMED and fixed, 2026-09-19.** The suspicion was right but understated, and the honest measure
  is not the depth of the cut -- it is the fraction of eroding cells *pinned at the cap*: **49.8%** on a
  400 m world, **80.6%** at 2 km, **92.1%** at 8 km. At that point the constant, not the physics, is
  setting the shape. Released, the same solver cut 122.96 m where the cap allowed 12.12 m.

  Two further defects fell out of measuring it:

  - **The clamp leaked.** The CELLS branch bounded the droplet's take by the *weighted mean* of its
    corners' remaining room, while `lay_at` moves cell i by `amt * scale * w_i`. A mean is not a bound: a
    corner with no room left and half the weight still received half of it. An 8 km world with a 2 m gap
    cut 3.186 m. Both unit modes now use the exact per-cell minimum.
  - **It could not be set by hand.** The export was `@export_range(0.1, 50.0, 0.5)` with no `or_greater`,
    so an 800 m mountain could not be given a sensible gap at all.

  `bedrock_gap` now defaults to **0 (off)** rather than 2 m. A relief-relative default was considered and
  rejected: relief is a whole-grid reduction, so the same terrain would get a different cap per tile and
  the solve would stop being local -- a real hazard next to `modifier_margin` skirts and per-brush baking.
  A floor is a deliberate, per-brush choice, so it is opt-in and now unbounded above.

  **It was also corrupting a gate.** `[U]` resolution invariance uses CELLS as its control, and a solver
  saturated against a constant reads as resolution-invariant for the wrong reason: the control had fallen
  to 0.013 and could no longer fail. With the default off it reads 0.405 against METRIC's 0.003. New
  criterion `[W]` holds the floor exactly, with the restored weighted mean as its break control (3.813 m
  and 9991 cells past the floor on that fixture). See [[erosion-should-run-on-brush-output]].
- **S3: MEASURED 2026-09-19, and the smaller half of a bigger defect.**

  The rim deposit is real but minor: on a 120 m dome ending in a step at its loop, the first 10 m outside
  the rim gained **+0.16 m**, of which **0.12 m** came from droplets spawned on the band (restricting the
  spawn to the loop leaves +0.04 m, with the interior unchanged). That much is arguably the skirt working
  as intended — the margin exists so sediment has somewhere to land.

  The defect underneath it is not: **`modifier_margin` rescales the erosion.** Same dome, same
  `droplet_count`, grids widened by a 0 / 60 / 150 m band → dome cut **21.712 m, 12.733 m, 7.271 m**. An
  absolute droplet count is spread over the whole working grid, so widening the band starves the dome. A
  setting documented as "room for the stack to work" is silently a threefold strength control.

  **A footprint mask does not fix it**, which is worth recording because it is the obvious first idea: a
  droplet whose spawn cell is masked off is *discarded, not redrawn*
  (`pasture_3d_hydraulic_particle.cpp`, "never runs"), so masking the band spends those droplets instead
  of concentrating them. Masked CELLS measured 21.853 / 12.546 / 7.326 — the same curve.

  So CELLS cannot be made margin-invariant without becoming METRIC: a density per unit area is precisely
  what "the margin must not matter" means. METRIC already holds (0.983 → 0.936 m, 4.8%). Gate `[M]` pins
  METRIC with CELLS as the control that must fail.

  **`units` now defaults to METRIC** (the user's call, 2026-09-19), on the same reasoning as S2: a default
  that does not scale is not a default. CELLS remains, because several criteria need it as the control.

  Switching it exposed that **five criteria were relying on CELLS being the default** rather than saying
  so — `[F]`, `[U]`, `[M]` and `[E3]`'s control arms silently became METRIC-vs-METRIC and stopped being
  able to fail. Every CELLS arm in the gate is now explicit, after which `[F]`'s frozen hash returned to
  its existing baseline unchanged, which is the evidence that the criteria were restored rather than
  re-fitted.
- **S4:** the grid GPU twin likely keeps the normalised outputs too. D10 therefore needs a GPU change,
  and gates [I], [J] and [K] in GraphGpuParityGate need re-baselining for the new channel meaning.
- **S5:** thread parity for the grid is claimed on a fixture I did not check for 128 or more rows with
  `parallel_dispatch_count`.
- **S6:** in the grid solver, `min_slope` goes through `PH[6] ? P[6] : 0.01`. This is fine as long as the lowering
  always writes it; worth a diff test.

---

## 4. Quality gaps against Salève and Strata

| Axis | Salève/Strata today | Particle | Grid |
|---|---|---|---|
| Metric units | dx in metres; resolution-stable | ✗ (cells) | Partial (dx is used for slope only) |
| Aux in metres, final surface | `eroded_rock` and `sediment` describe the final surface; gate [H] | ✗ (gross or fake) | ✗ (normalised suspended load) |
| Outlets and margin | `outlet_level`; rim-only fixes | ✗ (sediment vanishes at the edge) | ✗ (no outlets) |
| Native freeze with `key_defaults` | ✓ | ✗ | ✓ (grid port 0 plus scalars) |
| Lowering diff | Checked | Seed float32 (D6) | OK |
| Parity oracle | Tolerance plus control | ✗ (D1, D2) | ✓ (bitwise) |
| Thread and GPU | ✓ | Serial only | ✓ CPU; GPU exists |
| Controllability | Physical params | Magic `0.05` | Magic `0.4`/`0.6`/`0.5`/`10` |

---

## 5. Ranked improvement plan

Every item gets its own commit and its own gate with a failing control. **Look-risk** says whether tuned
scenes move. Where they would, the default keeps the old behaviour and a new parameter opts in, unless you
say otherwise.

All ten items shipped; the rank column carries the commit. See section 0 for where the plan below
turned out to be wrong.

| Rank | Item | Visual effect | Look-risk | Proving gate |
|---|---|---|---|---|
| P0 — not run | Run Hesiod's particle and pipe nodes next to ours on one exported heightmap, to settle the behavioural targets in section 2. | None | None | None (a written observation). **Not done:** the targets were settled from the published descriptions of the two models instead, and the GPL constraint means nothing could have been carried across from reading the code anyway. |
| 1 ✅ `0d449528` | **Particle parity (D1 and D2).** Take the quad differences in double in the native solver. Move the spawn skip into the native solver, or remove it from the oracle; the native behaviour is the one that ships, so I'd pick the oracle's semantics, which are what a mask implies. | None without a mask. With a mask, no more cutting driven in from masked-out regions. | **Yes, for masked scenes** (the mask edge moves). Unmasked scenes differ only by float noise. Chaotic amplification can still move individual channels, though, so I'll ask before shipping. | GraphHydraulicParticleGate [A3]: 2000 droplets at the default lifetime, with a tolerance. [A4]: a half-zero mask. Control: restore the float32 subtraction and see A3 fail. |
| 2 ✅ `43f5f072` | **Particle freeze and key (D4, D5, D6).** Add `freeze_key_grid_ports [0,1]` (in, mask; mask default 1.0 through `key_defaults`) and scalar ports [2,3,4]. Carry the seed as two float32 halves, or clamp it to 2^24 in the setter. Align the handling of seed 0. | None | None, except seeds above 2^24 | Add hydraulic_particle to GraphNativeFreezeGate `FREEZE_OPS`. A mask edit must stale the freeze; control: drop port 1 from the key. The GDScript, native and worker keys must be equal. |
| 3 ✅ `675dca44` | **Particle metric units (D3)** behind a new `units = METRIC` enum, with `CELLS` as the default. Step length, lifetime and radius in metres; droplets per 100 m²; slope divided by dx. | METRIC: same look at every resolution | None at the default | New ResolutionInvariance criterion: 64² vs 128² mean cut within 10%. Control: CELLS mode fails it (measured today: 19%). |
| 4 ✅ `40e99de0` | **Particle aux channels (D7, D8, D9).** Add `eroded` and `deposited` as net metres against the final surface (Salève-style), `flow` as droplet passes per m² normalised to a unit density, and `water_depth` in metres from the water volume. Deposit carried sediment at death, so mass is conserved. | The masks change meaning. Height changes only through the death deposit, which is opt-in. | **Yes, for anything wired to `sediment`/`flow`/`water_depth`.** The ports are renamed, and old names are removed outright per [[pre-stack-code-gets-deleted]]. I'll ask. | A GraphSaleveDepositionGate [H]-style criterion: deposited mean in the final trenches vs elsewhere, with the gross channel as the control. Mass balance: Σcut − Σdeposit − Σexited = 0 within tolerance. |
| 5 ✅ `675dca44` | **Particle erosion radius (Beyer).** Add a `radius_m` parameter, default 0, which is today's 4-corner behaviour. | Smoother channels, no pitting | None at the default | radius 0 must be bitwise equal to today. radius > 0 must lower the Laplacian energy of the channels. Control: a radius that is ignored fails it. |
| 6 ✅ `d731ce6f` | **Grid aux channels (D10, D13).** Output `eroded` and `deposited` in metres and `flow` as discharge (m³/s-equivalent). Settle the remaining suspended load at the end, behind a `settle_at_end` option (default off). Normalisation moves to Float to Mask. | The masks change meaning | **Yes, for wired masks**; ask first. The GPU twin changes too (S4). | Same as item 4, plus the GPU parity gates re-baselined with a control. |
| 7 ✅ `6841c0cf` | **Grid outlets (D11).** Add an `outlet_level` like Salève's, and let NaN act as an outlet. Default: current walls. | Rims stop ponding | None at the default | A margin criterion: cut within 10 m of the rim vs the interior, walls vs outlets. Interior change below tolerance ("fixes stay at the rim"). |
| 8 ✅ `907fc394` | **Grid metric scale (D12).** Contributing **area** in m² instead of summed rain, and a pass rate per unit time instead of 0.4/0.6. This is a real rewrite toward the Mei 2007 pipe model, so propose it as a **new mode** (`model = PIPE`), with Musgrave kept as the default. | PIPE: faithful channels, a `dt` parameter, velocity-based capacity | None at the default | Resolution invariance as in item 3, CPU/GPU parity for the new mode, and thread parity at 128 or more rows with `parallel_dispatch_count`. |
| 9 ✅ `5f45aaa2` | **Ridge forcing (S1).** Measure the handedness first. If it is confirmed, replace it with an unbiased perturbation, such as noise-signed rotation per droplet, or drop it. | Less sideways skew | **Yes, where rf > 0**; ask | The handedness criterion on a symmetric cone. Control: the current code. |
| 10 ✅ `ddfa2ff3` | Move the benchmark out of GraphHydraulicAccelerationGate [D] into its own bench (D15). Fix the header docs (D14). | None | None | The gate runs whole without timing. |

Items 1 and 2 are pure correctness and safe to ship first. Items 4, 6 and 9 change looks and need your
explicit go-ahead. Items 3, 5, 7 and 8 are opt-in.

*(Phase 2 outcome: the go-ahead was given for 4, 6 and 9 — replace the old ports outright, keep the
leftover-sediment deposits opt-in and default off, use an unbiased per-droplet ridge sign, and change the
grid GPU in the same commit as its CPU side. Items 3 and 5 were built together, as were the approvals for
7 and 8.)*
