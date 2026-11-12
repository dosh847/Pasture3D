# Pasture3D Wind Exposure Spec

Status: agreed 2026-11-12, unbuilt. Check the code before trusting this header.

## Goal

A **Wind Exposure** node that says, for every cell, how exposed it is to a prevailing wind. Its masks drive
erosion and look masks: exposed windward rock erodes, sheltered lee hollows keep soil, snow and sediment.

It is the wind analogue of Wave Exposure (op 72), and follows its conventions:
- the same bearing convention;
- the same one-sweep-per-direction architecture;
- the same param-block pattern;
- the same gate shape.

Every step follows `new-node-checklist`:
- maths in C++, shared kernels reused, a `*_params_from` shared by the binding and the op;
- `_param_changed()` setters, `_init` chaining `super()`;
- the op listed in `graph_op_ids()`;
- a gate where every criterion has a control that fails, plus a compiled-vs-GDScript parity check;
- port goldens re-recorded (`GraphPortTableWrite.gd`, `GraphPortProgramsWrite.gd`);
- GraphPortDescriptorGate, GraphPortIdGate and GraphPaletteAndConstantsGate re-run.

Out of scope, recorded in §11:
- per-cell direction fields and PATH-derived wind;
- a Wind Erosion solver;
- a GPU route.

---

## 1. Background: how other tools do it

No terrain tool surveyed has a wind-exposure *mask*. Wind appears as a texture or a simulation:

| Tool | What exists |
|---|---|
| Gaea | Wind Direction on the Sand and Dunes generators; Directed Erosion is guided by strokes, not wind. |
| World Machine | No wind device of its own; the third-party Geoglyph SandBlast blows sand (Strength, Dispersion, Deposits). |
| World Creator | The Drift → Wind filter streaks along the wind direction; Block Factor preserves the lee side. |
| Houdini | No wind node; the Sandpiles Advanced and Sand Transport VEX examples bias sand by a wind angle. |
| Instant Terra | Rock and thermal erosion only. |
| Unity Terrain Tools | Wind Erosion simulation; removes more from faces perpendicular to the wind. |

The exposure models live in GIS, and they are what this node draws on:

| Index | Idea | Parameters |
|---|---|---|
| Winstral Sx | Maximum upwind slope angle within `dmax`; positive = sheltered. Averaged over a sector. Sb = near Sx − far Sx marks drift-forming breaks. | `dmax` (~300 m), step, window (~30°), increment (~5°) |
| SAGA Wind Effect / Exposition (Böhner & Antonić 2009, Gerlitz et al. 2015) | Inverse-distance-weighted horizon angles, upwind against downwind, as a ratio around 1. Exposition averages over all directions. | MAXDIST, STEP (15°), ACCEL (1.5), PYRAMIDS (averaged elevations far away) |
| TOPEX | Sum of horizon angles in 8 directions within a limit (1–10 km). | limit, per-direction weights |
| Werner (1995) dune shadow zone | A cell is in wind shadow when it lies below a line falling at a fixed angle (≈15°) from upwind terrain. | shadow angle |

**Two algorithm families:**

- **Ray march (Sx, SAGA, TOPEX).** Each cell marches upwind. Cost O(N·K·S). To stay resolution invariant it
  needs a metre minimum distance and an averaged-elevation pyramid at range.
- **Shadow line (Werner).** It obeys a one-step recurrence, so it is one O(N) sweep per direction. It is exact
  on axis directions, has no search distance (the angle bounds the reach), and gives a depth in metres.

This spec uses the shadow line. It is exact against a closed form, linear in N, and in metres, which
`solver-outputs-are-metres` wants. It also reuses Wave Exposure's sweep.

---

## 2. Decisions

| # | Decision |
|---|---|
| D1 | Algorithm: the Werner shadow-line recurrence, one upwind sweep per direction (§3). |
| D2 | Direction: one prevailing bearing, as a property and a FLOAT value port. No per-cell direction field in this spec (§11.1). |
| D3 | Spread: K directions spaced evenly across `wind_direction ± spread`, uniform weights (the Sx sector). |
| D4 | Outputs, in order: `exposure` (MASK), `shelter` (FIELD, metres), `facing` (SIGNED, degrees). |
| D5 | The `exposure` mask uses fixed windows the user can see (`shelter_full` m, `facing_full` °). No AUTO window. Every other mask comes from Float to Mask on `shelter` or `facing`. |
| D6 | Optional input `obstacle` (FIELD, metres): height added to the shadow-casting surface only (forest canopy, walls, snow fences). It is not an output limiter; a Multiply node does that. |
| D7 | No `max_distance` in v1: the recurrence has no exact O(1) cap, and `shadow_angle` already bounds reach to relief / tan θ (§3.4). |
| D8 | Routes: production C++ kernel; hidden `[Dev/GD]` GDScript oracle; **no GPU kernel in v1** (§6.3). |
| D9 | Op `wind_exposure`, `GRAPH_OP_WIND_EXPOSURE = 80`. Re-check that 80 is still free when building. Category Masks, role FILTER. |
| D10 | Wave Exposure's bilinear predecessor and visit order move into a shared header first, and Wave Exposure must stay bit-identical (§7, step 1). |

---

## 3. Algorithm

### 3.1 Conventions

- A bearing is where the wind blows **from**: 0 = north (−Z), 90 = east (+X). This matches Wave Exposure and
  Slope's `aspect`.
- For bearing `a`, the upwind unit vector in grid space is `u = (sin a, −cos a)`.
- The step `s = u / max(|ux|, |uz|)` has its larger component exactly one cell, so the predecessor of a cell
  always lies in the previous row or column. Its length in metres is `L = sqrt((sx·dx)² + (sz·dz)²)`.
- `pred(arr, c)` is the bilinear read of `arr` at `c + s`, from cells already visited. Visit order and the
  off-grid flag are exactly Wave Exposure's.

### 3.2 Shelter: one sweep per direction

With `z` the height, `o` the obstacle (0 unwired), `z' = z + o` and `t = tan(shadow_angle)`:

```
S[c]       = max(pred(z', c), pred(S, c)) − L·t        // shadow-line height over c
             S[c] = NONE when any predecessor tap is off the grid or non-finite
shelter_k  = max(0, S[c] − z[c])                       // metres below the shadow line
```

- `NONE` is a large negative sentinel, `−1e30`. A finite tap mixed with it in the bilinear read stays hugely
  negative, so `max` takes the terrain. S is clamped to `≥ NONE` after the subtraction.
- **Off the grid is "no terrain".** Nothing upwind of the grid casts a shadow (§5.2 covers the margin).
- A cell is never sheltered by itself or by its own obstacle; only upwind cells cast.
- A non-finite `z[c]` reads `shelter = 0`, `facing = 0`, `exposure = 0`, and casts nothing.

**Closed form, used by the gate.** On an axis direction the bilinear read is a single tap. A block of height
`H` on flat ground at 0 then shelters the cell `j` cells downwind of its last cell by exactly
`max(0, H − j·dx·t)`.

### 3.3 Facing: slope into the wind

```
zs        = box_mean_solve(z, facing_scale)            // raw z when facing_scale = 0
(gx, gz)  = metric_gradient(zs, ...)                   // the shared metric gradient (terrain_metrics.h)
facing_k  = degrees(atan(−(gx·ux + gz·uz)))            // + windward (faces upwind), − lee
```

Facing reads the bare height, never the obstacle.

### 3.4 Directions and the mean

- K = `directions`, forced to 1 when `spread == 0`.
- For K > 1, `θ_k = wind_direction + spread·(2k/(K−1) − 1)`, k = 0..K−1, each with weight 1/K.
- An odd K keeps the centre direction, and an axis wind then keeps that sweep exact. An even K gets a node
  warning, like Wave Exposure's multiple-of-four warning.

```
shelter = Σ shelter_k / K        facing = Σ facing_k / K
```

**Reach.** A relief of `R` metres shelters at most `R / t` metres downwind: 3.7 R at 15°, 1.7 R at 30°.
That is the node's only distance control (D7). The inspector help says so.

### 3.5 Exposure

```
ss01(x)  = smoothstep(0, 1, clamp(x, 0, 1))
open     = 1 − ss01(shelter / shelter_full)
face     = ss01(0.5 + 0.5·facing / facing_full)        // lee face 0, flat 0.5, windward 1
exposure = open · lerp(1, face, facing_weight)
```

- With `facing_weight = 0`, exposure is pure shelter: unsheltered ground reads 1, whatever its slope.
- With `facing_weight = 1`, flat open ground reads 0.5, and full exposure needs a windward face.

### 3.6 Threading and determinism

- Directions are independent; each owns its `S` buffer and per-direction outputs. The pool runs over
  directions (`Pasture3DThreadPool`).
- The final sums are taken in k order after all sweeps, so the result does not depend on the thread count.
- Inside a direction the sweep is serial (row-to-row dependency), as in Wave Exposure.
- The box mean for facing is computed once, not per direction.

---

## 4. Ports and parameters

### 4.1 Inputs

| # | id | type | notes |
|---|---|---|---|
| 0 | `height` | HEIGHT, required | |
| 1 | `obstacle` | FIELD, metres, unwired 0 | Native field input `in1`. Adds to the shadow-casting surface only. |
| 2 | `wind_direction` | FLOAT value port → property `wind_direction`, native slot 0 | |

- The node declares no `mask` port. Its port 0 output is a MASK, so the framework adds no standard mask
  (ports spec §9).
- It uses two of the four native field inputs, with no aux grid (`native-op-four-field-inputs`).

### 4.2 Outputs (a wire format: APPEND only)

| # | id | type | unit |
|---|---|---|---|
| 0 | `exposure` | MASK | 0..1 (§3.5) |
| 1 | `shelter` | FIELD | metres below the wind-shadow line, sector mean |
| 2 | `facing` | SIGNED | degrees, slope angle into the wind, sector mean |

`native_out_count() = 3`. Channels 1 and 2 go out through `want_aux(1)` and `want_aux(2)`.

### 4.3 Parameters: the sixteen-slot block

`wind_exposure_params_from(P, 16)` is shared by the `Pasture3DUtil.wind_exposure_grid` binding and the op.

| slot | property | default | range | meaning |
|---|---|---|---|---|
| 0 | `wind_direction` | 0 | 0–360 ° | bearing the wind blows FROM |
| 1 | `spread` | 30 | 0–180 ° | half-width of the direction sector |
| 2 | `directions` | 7 | 1–64 | K; forced to 1 at spread 0 |
| 3 | `shadow_angle` | 15 | 1–60 ° | angle of the shadow line (Werner's 15°) |
| 4 | `facing_scale` | 20 | 0–500 m | box-mean radius before the gradient; 0 = raw |
| 5 | `shelter_full` | 10 | > 0 m | shelter depth that reads fully sheltered |
| 6 | `facing_full` | 30 | 1–89 ° | facing angle that reads fully windward / lee |
| 7 | `facing_weight` | 0.5 | 0–1 | how much facing shapes `exposure` |
| 8–15 | — | | | reserved |

- Setters call `_param_changed()` and clamp as the ranges say. The kernel clamps again in `*_params_from`.
- Parameters round-trip as float32 on both routes (`graph-program-params-are-float32`).
- `edit_reach()` keeps the base answer, INF (`needs_grid()`).

### 4.4 Registry entry

```
{"op": &"wind_exposure", "title": "Wind Exposure", "category": "Masks", "role": "Filter",
 "tags": ["wind", "exposure", "shelter", "lee", "windward", "shadow", "drift", "snow", "erosion",
          "aspect", "prevailing"],
 "description": "How exposed each cell is to a prevailing wind: the depth below the wind-shadow line
  cast by upwind terrain (metres), the slope into the wind (degrees), and an exposure mask built from
  both. Drive an erosion node's mask with exposure, or take a lee mask from shelter with Float to Mask."}
```

The `[Dev/GD]` oracle (`dev_wind_exposure`) goes in `_dev_entries()` under "Dev / Reference".

---

## 5. Behaviour at the edges

### 5.1 Region and brush edges

Shelter at a cell depends on terrain up to `R / t` upwind. Off-grid is "no terrain", so cells within that
distance of the upwind border read less shelter than the full world would give.

- Inside a brush, the modifier margin skirt supplies that context (`modifier-margin-skirt`). The inspector
  help tells users to cover the reach with the margin when lee features sit near the brush edge.
- Tiled regions do not exchange shadows across region edges in v1, the same as Wave Exposure's fetch.

### 5.2 Why not "edge = continued terrain"

Continuing the edge height upwind casts nothing on its own: a flat continuation's shadow line falls below the
edge cell after one step. An `edge_open` flag would therefore be a no-op, so there isn't one.

---

## 6. Routes

### 6.1 GDScript `[Dev/GD]` oracle

- File: `pasture3d_graph_node_dev_wind_exposure.gd`. Hidden behind
  `pasture_3d/developer/enable_gdscript_reference_nodes`.
- Literal per-direction sweeps in double precision, with its own bilinear predecessor written out. Its facing
  uses the oracle box mean from `pasture3d_graph_node_dev_terrain_metrics.gd`, not a third copy.
- It is the oracle for gate criterion I. It does not need to be fast.

### 6.2 Native C++: the production route

- Kernel: `src/pasture_3d_wind_exposure.{h,cpp}`. The header explains the recurrence and its closed form, as
  Wave Exposure's does.
- `WindExposureParams` plus `wind_exposure_params_from(const float*, int)`.
- `Dictionary wind_exposure_grid(height, obstacle, gw, gh, rect, params)` returns
  `{exposure, shelter, facing}`. An empty `obstacle` reads 0.
- Reused, not re-derived:
  - the shared upwind sweep (§7, step 1);
  - `box_mean_solve` and `metric_gradient` (terrain_metrics.h);
  - `Pasture3DThreadPool`.
- Binding: `Pasture3DUtil.wind_exposure_grid(height, obstacle, gw, gh, rect, params)`.
- Op: `GRAPH_OP_WIND_EXPOSURE` in `pasture_3d_graph_ops.h`, a case in `pasture_3d_graph_ops.cpp` reading
  `in0` and `in1` with `P[]` resolved (so a wired `wind_direction` reaches slot 0), the `graph_op_ids()` row
  in `pasture_3d_util.cpp`, and `compile_graph_program` / `native_supported` in
  `pasture3d_terrain_graph.gd`.
- The production node's `eval_grid_channels` calls the binding and fails fast with `push_error` when it is
  not bound (Wave Exposure's pattern). The safe fill is `exposure = 0`, `shelter = 0`, `facing = 0`.

### 6.3 GPU: none in v1

- The node joins ops 71–75 as CPU-only. A graph holding it drops the whole graph to CPU
  (`graph-gpu-bail-is-graph-wide`). Record that in the inspector help, as for Wave Exposure.
- A sweep has a row-to-row dependency, so it does not fit one GPU dispatch. The future route is a per-cell
  bounded ray march as a new GPU shader mode:

  ```
  shelter_k = max_j (z'(c + j·s) − j·L·t) − z(c),   j = 1..ceil(R_grid / (L·t))
  ```

  `R_grid` is the grid's height range plus the maximum obstacle.
- This equals the recurrence **exactly on axis directions** (single taps). On oblique directions it differs,
  because the recurrence compounds bilinear reads and the march does not. A GPU route therefore needs its own
  parity tolerance, measured as in `gpu-division-flips-exact-stop-hits`, and a criterion pinning
  axis-direction equality.

---

## 7. Build order

1. **Shared sweep.** Move Wave Exposure's `pred` lambda, visit order and step/`L` setup into
   `src/pasture_3d_upwind_sweep.h` (header-only, inline). Switch Wave Exposure to it.
   - Regression check: GraphWaveExposureGate WA–WF green, plus a one-off hash of the exposure and fetch
     outputs on its fixture, before and after, that must match bit for bit.
   - Control for that check: a deliberately perturbed step (`L·(1+1e-6)`) changes the hash.
2. **Kernel, binding, op, oracle and node** as §4 and §6, then the gate (§9).
3. **Port goldens and standard gates** re-recorded and re-run (checklist).

---

## 8. How it feeds erosion

| Use | Wiring |
|---|---|
| Erode exposed rock only | `exposure` → the standard `mask` of Thermal Erosion, Salève Hydraulic Erosion, etc. |
| Sheltered lee deposits (snow, soil, sand) | `shelter` → Float to Mask (FIXED, e.g. 0–5 m) → a colour layer or a raise |
| Windward faces only | `facing` → Float to Mask (e.g. 5–30°) |
| Coastal cliffs facing the storm wind | `exposure` × Wave Exposure `exposure` → Coastal Erosion's `exposure` port |
| Hedges or forest cast shelter | a forest height field → `obstacle` |

---

## 9. Gate plan: `bench/GraphWindExposureGate.gd`

**Fixtures.**
- Cells of 8 m on `Rect2(-512, -512, 1024, 1024)` at 128², unless stated.
- Flat ground at 0 with a 20 m block x ∈ [−40, 40], z ∈ [−200, −160] (the "wall").
- An east–west ridge (Gaussian, 60 m high, σ 60 m) for C.

Every criterion has a control that fails. The gate asserts `_ran == 10` (`gate-pass-can-mean-nothing-ran`).

| | Criterion | Control that fails |
|---|---|---|
| A | **Exact shadow.** Wind from north, `spread = 0`, `facing_weight = 0`: every cell's `shelter` equals `max(0, H − j·dx·tan 15°)` behind the wall and 0 elsewhere, worst ≤ 1e-3 m. | The same formula for a wind from the south misses by ≥ 15 m. |
| B | **The angle sets the length.** The last sheltered cell behind the wall is `floor(H / (dx·tan θ))` cells downwind, for θ = 15° and 30°. | The 30° run checked against the 15° length is wrong by ≥ 3 cells. |
| C | **Windward and lee.** North wind on the ridge: the south flank has `shelter > 1 m` and `facing < −5°`; the north flank has `shelter == 0` and `facing > 5°`. | A south wind: the same assertions at the same cells fail (the flanks swap). |
| D | **Spread.** A cell 3 cells downwind and 8 cells east of the wall's east end reads `shelter == 0` at spread 0 and `> 0` at spread 45°. | The cell straight behind the wall reads `> 0` at both, so this is not 0 against 0. |
| E | **Obstacle.** Flat ground, obstacle 10 m on one row: `shelter > 0` downwind, and `facing` identical (≤ 1e-6) to the unwired run. | Unwired, `shelter` is exactly 0 everywhere. Feeding the obstacle into `height` instead changes `facing` by > 1°. |
| F | **Exposure is its formula.** `exposure` equals §3.5 computed in the gate from the `shelter` and `facing` channels at every cell, ≤ 1e-5. | The same formula with `facing_weight` 0 instead of 0.5 differs by > 0.1 somewhere. |
| G | **Resolution invariance.** A deterministic metre-space terrain (summed sines, wavelengths 300 m and 120 m, amplitude 40 m), solved at 128², 256² and 512² over the same rect. Box-average `shelter` and `facing` to 64², take RMS gaps relative to the field: gap(256, 512) < gap(128, 256), and gap(256, 512) < 0.1 (`resolution-invariance-needs-field-metric`). | The same solve with `Rect2(0, 0, g, g)` (grid units): its gaps do not shrink, or exceed 0.5. |
| H | **Compiled route = GDScript evaluator.** Input → Wind Exposure → Output: `native_supported()`, and `compile_graph_program` + `graph_eval_grid` equals `force_gdscript_evaluation` within 1e-4 for each output port, with `wind_direction` unwired, wired to a Const 90, and with `obstacle` wired. | Wiring `wind_direction = 180` moves `exposure` by > 0.1; the `shelter` channel is not `exposure` (> 1 m apart somewhere). |
| I | **Kernel = oracle.** The `[Dev/GD]` oracle equals the native kernel on an oblique wind (37°, K = 5, spread 20°) on the ridge plus the wall, ≤ 1e-4 for all three channels. | The oracle at 38° differs from native at 37° by > 1e-2. |
| J | **Stays native.** `wind_exposure` is in `graph_op_ids()`. | A bogus op is not. |

**Notes.**
- H runs at 128 rows, so the thread pool is not serial (`thread-parity-needs-128-rows`).
- A and B depend on spread 0 forcing K = 1. A also asserts K = 1 was used: with K = 7 and spread 0 the result
  is identical, which is part of what A checks.
- G is the only timed-scale criterion (512²). It is not a performance test, but it is the slowest; it stays
  under a few seconds on the native route. Ask before adding any timing (`ask-before-perf-tests`).
- Godot quit crash 0xC0000005 after PASS is pre-existing (`godot-quit-crash-offset-5472f6`).

Run: `Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphWindExposureGate.tscn`

---

## 10. Files

| New | |
|---|---|
| `src/pasture_3d_upwind_sweep.h` | shared predecessor, visit order, step |
| `src/pasture_3d_wind_exposure.{h,cpp}` | kernel |
| `project/addons/pasture_3d/graph/pasture3d_graph_node_wind_exposure.gd` | production node |
| `project/addons/pasture_3d/graph/pasture3d_graph_node_dev_wind_exposure.gd` | oracle |
| `project/bench/GraphWindExposureGate.{gd,tscn}` | gate |

| Changed | |
|---|---|
| `src/pasture_3d_wave_exposure.cpp` | uses the shared sweep, bit-identical |
| `src/pasture_3d_graph_ops.{h,cpp}`, `src/pasture_3d_util.{h,cpp}` | op 80, binding, `graph_op_ids` |
| `pasture3d_terrain_graph.gd`, `pasture3d_graph_node_registry.gd` | lowering, registry |
| port goldens | re-recorded |

---

## 11. Later (out of scope here)

### 11.1 Direction fields (to explore)

A per-cell wind bearing: valley winds, katabatic flow from Slope's `aspect` + 180°, or a wind drawn as a
spline. The sweep can take one without changing architecture:
- sweep K fixed directions around the full compass;
- weight each cell's contribution by its own bearing ± spread, so the sector average becomes per cell.

Cost becomes O(N·K) with K covering 360°. The port would be an optional `direction` FIELD (degrees),
appended, so it is not a format bump. A PATH-to-bearing node (Path Direction) would feed it, rather than this
node reading paths itself. This needs its own discussion: kernel width, how bearings wrap at 0/360 when
averaged, and what a gate for a curving wind looks like.

### 11.2 Wind Erosion solver

A solver that abrades windward faces in proportion to exposure and deposits in the lee: drifts, loess,
dunes behind obstacles. It would consume this node's outputs, or its kernel.

### 11.3 GPU route

As §6.3. Worth doing once a graph that needs the GPU holds this node.

### 11.4 Distance cap and decay

A `max_distance` or a shadow that recovers with distance (real wakes reattach after about 10–20 H). Neither
has an exact O(1)-per-cell form on the recurrence. A ray-march variant could carry both, at O(N·K·S).
