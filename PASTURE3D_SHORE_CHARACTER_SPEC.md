# Pasture3D Shore Character Spec

Status: step 1 built 2026-11-10 (uncommitted at time of writing); steps 2–3 unbuilt. Check the code before trusting this header.

## Goal

Make the island coast choose its own beaches and cliffs, and make cliffs vary and soften the way real
coasts do, so a hand-drawn beach spline is only needed where the user wants a specific look.

Three changes, built and committed in this order. Each one stands on its own and is useful without the next.

1. **Coast Profile:** `cliff` sets the cliff's steepness, not whether it exists.
2. **Shore Character:** a new node that outputs procedural `cliff`, `beach` and `erosion` masks.
3. **Coastal Erosion:** retreat varies along the coast, and sheltered faces slacken and round over.

Every step follows `new-node-checklist`:
- maths in C++, shared kernels reused, a `*_params_from` shared by the binding and the op;
- `_param_changed()` setters;
- the op listed in `graph_op_ids`;
- a gate where every criterion has a control that fails, plus a compiled-vs-GDScript parity check;
- port goldens re-recorded;
- GraphPortDescriptor, PortId, PaletteAndConstants and StandardMask gates re-run.

## Background: what is wrong today

- **The beach zone is a notch.** Coast Profile's land term is
  `beach_height·ss(d/bw) + cliff_height·c·ss((d − bw)/cliff_width) + inland(...)`. At c = 0 the whole
  `cliff_height` (30 m) is dropped. The plateau either side keeps it, so a beach-masked stretch becomes a
  trench 30 m deep, walled where the mask feathers out.
- **Beaches are drawn by hand.** Every beach needs its own spline. Nothing in the graph knows where sand
  would collect.
- **Erosion is a parallel offset.** Coastal Erosion retreats by `retreat × exposure` with one fixed
  `cliff_angle`. Exposure varies slowly, so the cliff moves inland as the same wall. That gives no coves, no
  headlands and no softened slopes.

---

## Step 1 — Coast Profile: `cliff` is steepness

### Change

Always apply the cliff height. The cliff weight `c` only sets how wide the rise is:

```
w_c  = lerp(slope_width, cliff_width, c)          // c = 1: cliff_width; c = 0: slope_width
bw   = beach_width · (1 − c)                      // unchanged
land = beach_height·ss(d/bw)
     + cliff_height·ss((d − bw)/w_c)
     + inland_height·ss(x)^inland_curve,  x = (d − bw − w_c)/inland_width
```

At any c, the profile reaches the same height `beach_height + cliff_height` at the start of the inland rise.
Only its steepness changes. A beach zone now climbs to the plateau over `slope_width` metres instead of
leaving a trench.

The sea side (`d < 0`) is unchanged.

**Seam behaviour.** Because the inland rise starts at `bw + w_c`, the inland term shifts outward where c is
low. Over a feathered mask this is a smooth shift, not a step. The smoothstep keeps every band boundary at
zero slope.

### Parameters

| Slot | Name | Default | Notes |
|---|---|---|---|
| 13 | `slope_width` | 150 m | the rise width where `cliff` = 0. Clamp ≥ `cliff_width`. |

New export on the node, in the "Cliffs" group, with a `_param_changed()` setter.

### Outputs

The `cliff` output stays a band mask. Its band is now `[bw, bw + w_c]`, weighted by c as today, so it marks
the rise however steep it is. **Behaviour change:** the band is wider where c is low. State this in the
node description.

### Migration

The look of existing graphs changes wherever `cliff` < 1. A graph with `cliff` unwired reads c = 1 and
keeps its old look exactly. Re-bake `demo_island` and commit that separately as `chore(demo)`.

### Gate: extend GraphCoastProfileGate

| ID | Criterion | Control |
|---|---|---|
| CG | At c = 0 and c = 1, the height at `d = bw + w_c` equals `beach_height + cliff_height` (± 1e-4). | The pre-change formula, evaluated in the gate at c = 0, misses by `cliff_height`. |
| CH | With c = 0, the largest slope across the rise is ≤ `cliff_height · 1.5 / slope_width`. | At c = 1 the largest slope is above `cliff_height / cliff_width`. |
| CI | With `cliff` unwired, the output is bit-identical to a run with an explicit all-1 mask, and the c = 1 closed form still holds. | — |

---

## Step 2 — Shore Character node (op 75)

**Category:** Masks. **Role:** FILTER. **No standard mask:** port 0's output is a MASK.

### What it computes

For every cell, a cliff weight from coastal signals. Each signal is 0..1, where higher means "more cliff".

| Signal | How | Shared kernel |
|---|---|---|
| **Shape** (headland vs bay) | Land fraction in a disc of radius R, from the inside mask, by box blur. Under 0.5 = in a bay (beach), over 0.5 = on a headland (cliff). `shape = ss((f − 0.5)·gain + 0.5)`. Two radii, `bay_radius` (300 m) and `cove_radius` (60 m), averaged. | the existing separable box or gaussian blur. **Survey before writing:** whichever kernel Smooth uses. |
| **Exposure** | From the `exposure` input, read as is. Unwired reads 1. | — |
| **Backshore** | Height of the ground `backshore_dist` (80 m) inland, as 0..1 over `backshore_height` (40 m). High ground = cliff. Sampled at the nearest land cell that far from the sea. | `distance_transform_solve` (JFA, metres) |
| **Valley mouths** | `flow` input (MASK, unwired 0), e.g. Float to Mask of a flow output. High flow = beach. Enters as `1 − flow`. | — |
| **Hardness** | Value noise in world metres along the coast, wavelength `hardness_scale` (400 m), seeded. Amplitude `hardness_variation`. | the shared noise. **Survey:** the Fractal node's value or perlin kernel and `wang_hash`. Do not write a new noise. |

```
cliff_raw = Σ wᵢ·signalᵢ / Σ wᵢ          // weights: shape 1.0, exposure 0.7, backshore 0.5, valley 0.5
cliff     = ss((cliff_raw − threshold)/softness + 0.5)
hardness  = clamp(0.5 + hardness_variation·(noise − 0.5), 0, 1)
erosion   = exposure · (1 − hardness)      // what Coastal Erosion reads (step 3)
```

The signals are defined on land and water alike. The outputs are only meaningful within about
`bay_radius` of the shore, and the node does not mask them beyond that.

### Inputs

Inputs are limited to `in0` plus one aux grid (`native-op-four-field-inputs`), so the design keeps to that.

| Port | Id | Type | Notes |
|---|---|---|---|
| 0 | `height` | HEIGHT, required | Coast Profile's output with `cliff` unwired. Land/sea and backshore come from it. |
| 1 | `exposure` | MASK, unwired 1, aux | Wave Exposure on the same height. |
| 2 | `sea_level` | value, slot 0 | |

The **valley** signal is dropped from v1, because a second grid input is not allowed. Add it later as a mode
that reads the aux port, or by combining flow into exposure upstream. Record this as a known limit in the
node header.

**Why from height, not the outline path?** The shape signal needs a land mask, and height gives one for any
coast: drawn, eroded or brushed. A PATH input would only work for Coast Profile's outline.

### Outputs (APPEND only)

| Port | Id | Type |
|---|---|---|
| 0 | `cliff` | MASK |
| 1 | `beach` | MASK, = 1 − cliff |
| 2 | `hardness` | MASK |
| 3 | `erosion` | MASK |

### Parameters

| Slot | Name | Default |
|---|---|---|
| 0 | `sea_level` | 0 |
| 1 | `seed` | 0 |
| 2 | `bay_radius` | 300 m |
| 3 | `cove_radius` | 60 m |
| 4 | `shape_weight` | 1.0 |
| 5 | `exposure_weight` | 0.7 |
| 6 | `backshore_weight` | 0.5 |
| 7 | `backshore_dist` | 80 m |
| 8 | `backshore_height` | 40 m |
| 9 | `threshold` | 0.5 |
| 10 | `softness` | 0.2 |
| 11 | `hardness_scale` | 400 m |
| 12 | `hardness_variation` | 0.6 |

### Intended wiring (in the node description)

```
outline → Coast Profile A (cliff unwired) ─┬→ Wave Exposure ─→ Shore Character.exposure
                                           └→ Shore Character.height
Shore Character.cliff ─(Max/Min with the beach-spline Path Mask)→ Coast Profile B.cliff
Coast Profile B → Coastal Erosion (exposure ← Shore Character.erosion) → Islet Scatter → Output
```

Coast Profile A is cheap (a closed-form profile), so running two is fine. The user's spline becomes an
override on top.

### Files

- `src/pasture_3d_shore_character.{h,cpp}`
- op enum `GRAPH_OP_SHORE_CHARACTER = 75`, its case block, the `k_ops` row, and the
  `Pasture3DUtil.shore_character_grid` binding
- `pasture3d_graph_node_shore_character.gd` and its registry entry
- `bench/GraphShoreCharacterGate.{gd,tscn}`

### Gate: GraphShoreCharacterGate

Fixture: a square island with one deep bay and one narrow headland, sea at −10 m, land at +10 m.

| ID | Criterion | Control |
|---|---|---|
| SA | With only shape weighted, the bay head reads `cliff` < 0.3 and the headland tip > 0.7. | Shape weight 0 (only a uniform exposure weighted) makes both equal. |
| SB | With only exposure weighted, the cliff output follows the exposure input: ramps 0→1 give monotonic cliff. | Exposure unwired gives a uniform cliff. |
| SC | Backshore: raising the land behind one shore to +60 m raises that shore's cliff and leaves the far shore within 1e-6. | Backshore weight 0 leaves both unchanged. |
| SD | Hardness is in world metres: the 64² and 128² hardness agree within 0.05 at shared points. | A different seed differs by > 0.2 somewhere. |
| SE | `erosion` = `exposure · (1 − hardness)` exactly. `beach` = `1 − cliff` exactly. | — |
| SF | The compiled program equals the forced GDScript evaluator for all four channels, exposure wired and unwired, and is native_supported. | Each channel differs from the others. |
| SG | No standard mask; the op is in `graph_op_ids`. | A bogus op is not. |

---

## Step 3 — Coastal Erosion: varied retreat, sheltered slackening

### Change

**The exposure input is now read as erosive energy.** No new grid port is added, because of the one-aux
limit. The user wires Shore Character's `erosion` (exposure × softness) into it, so the retreat
`R = retreat × input` already varies with hardness. That gives coves where rock is soft and headlands
where it is hard. Wave Exposure wired directly still works as before. Update the port tooltip and the
node description.

**Slackening.** The talus angle per cell is:

```
angle = lerp(slack_angle, cliff_angle, e)          // e = the input at that cell
```

`talus_projection_solve` takes one angle today. **Survey it first:**
- If it can take a per-cell slope array cheaply, add an overload with an optional per-cell array. Keep the
  scalar path bit-identical, because other callers depend on it.
- Otherwise, run it on a few binned angles and blend. That is less exact and needs its own gate case.

**Crest rounding.** The talus band grows from "cut cells + one-cell rim" to
"cut cells + every land cell within `crest_reach` of a cut cell", by JFA distance from the cut mask. The
cliff top can then round over and fall back. In sheltered stretches, with a low angle, that turns the cliff
into a slope that runs down to the beach Coast Profile built.

### Parameters

| Slot | Name | Default | Notes |
|---|---|---|---|
| 8 | `slack_angle` | 30° | the face angle at energy 0 |
| 9 | `crest_reach` | 20 m | how far past the cut the talus may move ground |

**Iterations.** `cliff_iterations` limits how far talus propagates, about one cell per pass. With
`crest_reach` = 20 m at 4 m cells that is 5 cells. Document the rule
`cliff_iterations ≥ crest_reach / cell` in the tooltip, rather than coupling them silently.

### Behaviour changes

- With `slack_angle` = `cliff_angle` and `crest_reach` = 0, the output must be **bit-identical** to today.
  Gate this.
- The new defaults (30°, 20 m) change the look of existing graphs. Re-bake the demo as `chore(demo)`.

### Gate: extend GraphCoastalErosionGate

| ID | Criterion | Control |
|---|---|---|
| CG | `slack_angle` = `cliff_angle` and `crest_reach` = 0 is bit-identical to the pre-change kernel. Pin a stored checksum before changing the kernel. | Defaults differ from the checksum. |
| CH | On the existing fixture's sheltered half with exposure 0.2, the largest face slope is ≤ `tan(lerp(30, 70, 0.2)) + 0.1`. | At `slack_angle` = 70, the same face exceeds it. |
| CI | `crest_reach` = 20: land within 20 m of the cut moves. Land 3+ cells beyond `crest_reach` is bit-identical to the input. | `crest_reach` = 0 moves nothing beyond the rim. |
| CJ | Varied retreat: an input that alternates 0.2/1.0 in 100 m stripes along the coast produces a retreat line with ≥ 3 coves, each > 15 m deep. | A uniform 0.6 input produces a straight retreat line, with < 2 m variation. |
| CD | The existing compiled-vs-GDScript parity check, re-run with the new params non-default. | — |

---

## Out of scope

- A GPU route for any of the four island nodes. All of them stay CPU only.
- The valley-mouth signal, which needs a second grid input.
- Sediment moving from cliffs to beaches. Coastal Erosion stays a shaping model, not mass-conserving.
- Timing. Ask before running any performance test, because the machine is shared.

## Commits

1. `feat(graph): Coast Profile cliff mask sets steepness, not height`, then `chore(demo)`.
2. `feat(graph): Shore Character node for procedural cliffs and beaches`.
3. `feat(graph): Coastal Erosion varies retreat and slackens sheltered cliffs`, then `chore(demo)`.
