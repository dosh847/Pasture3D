# Pasture3D Brush & Terrain Node Graph — Pipeline Remediation

**Document:** `PASTURE3D_PIPELINE_REMEDIATION_SPEC.md`
**Status:** **NOTHING BUILT** — written 2026-09-03 from a full-subsystem review of the brush and
terrain node graph pipeline at `main` @ `3f753604`. No phase started.
**Scope:** `src/pasture_3d_brush_raster.cpp`, `src/pasture_3d_graph_ops.cpp`,
`src/pasture_3d_graph_gpu.cpp`, `src/shaders/graph_solver_hydraulic.glsl`,
`project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd`,
`project/addons/pasture_3d/connectors/pasture3d_mod_*.gd`,
`project/addons/pasture_3d/graph/pasture3d_terrain_graph.gd`,
`project/addons/pasture_3d/src/graph_editor.gd`.
**References:** `PASTURE3D_NODE_ACCELERATION_GUIDE.md`, `PASTURE3D_BRUSH_PERPOINT_SPEC.md`,
`PASTURE3D_SOLVER_NATIVE_ACCELERATION_SPEC.md`, `PASTURE3D_TERRAIN_GRAPH_SPEC.md`.

---

## 0. How this document is ordered, and why

Six phases, ordered by **what the user loses**, not by where the code lives:

| Phase | What it fixes | Why it is at this rank |
|---|---|---|
| **P1** | The GPU path silently disagrees with the CPU path | Wrong terrain ships, and *nothing says so*. The divergence appears only above a size threshold, so it looks like a modelling mistake, not a bug. |
| **P2** | The native CPU rasteriser/evaluator produces wrong output | Wrong terrain, but at least deterministic and reproducible at any size. |
| **P3** | The deferred bake driver hangs, freezes, or corrupts a neighbour | The editor becomes unusable for the session, or a *different* brush's terrain is damaged. |
| **P4** | Caches serve data that belongs to another node, another place, or another parameter value | Wrong output that survives a re-bake and hides behind a "not stale" flag. |
| **P5** | Editor-lifetime defects: leaks, stale signal bindings, undo asymmetry | Annoyance and slow degradation, not wrong terrain. |
| **P6** | The structural debt that *caused* several P1–P4 bugs | Deferred deliberately: fixing it first would rebase every earlier phase. |

**Phases P1–P4 are independent of each other and may land in any order or in parallel.** P5 is
independent too. P6 must land *last*, because it rewrites the surfaces P1 and P4 touch — doing it
first means every earlier fix is written against a structure that then moves.

Two rules carried from prior rounds, and they bind here:

- **Every criterion needs a control that fails.** A gate that cannot distinguish "measured nothing"
  from "measured well" is not a gate. Several bugs below are exactly the kind an existing gate should
  have caught and did not — see §7.4.
- **Deprecated code is deleted, not shimmed.** No compatibility wrappers for the dead functions in §6.


## 0.1 Interaction with `PASTURE3D_BRUSH_REBAKE_LOOP_SPEC.md` (landed 2026-09-03)

That spec's four phases and commit `2e4a3880` landed *after* this review's findings were gathered.
They were re-checked against every phase below. Nothing in this document contradicts them, but four
items change in force, and three new items are folded in.

**Changes in force**

1. **§3.3 is now a prerequisite, not an improvement.** Phase 2 added
   `if reseeded and not _erosion_running and not _growth_defer: _schedule_refresh()` to
   `_commit_modifier_caches`. That guard is correct *only if both flags are reliably cleared*. §3.3
   proves `_erosion_running` is cleared exclusively inside `_bake_deferred`, so either abort in §3.2
   sticks it true forever — and the guard now hangs a second consequence on that: DLA seed surfaces
   stop re-converging too, on top of the dead auto-refresh §3.3 already describes. **§3.3 must land
   before the reseed guard can be relied on**, and §3.7's gate must cover the flag-stuck case
   explicitly (its control: abort mid-bake, then assert a reseed still schedules).
2. **§4.1 rises in priority.** Phase 1 removed `emit_changed.call_deferred()` from `set_stale()` on
   `pasture3d_mod_relief.gd`, `_erosion.gd`, `_graph.gd` and from `Pasture3DReliefDLA._mark_stale()`:
   the team has now decided that emitting `changed` from a staleness setter is a re-entrancy bug.
   §4.1 is the surviving instance of exactly that pattern in a different hierarchy — twenty solver
   `clear_cache()` overrides that call `emit_changed()` and re-enter `_on_node_changed` mid-eviction.
   Treat it as the same defect class, not as unrelated cache tidying.
3. **§2.3 must not break the new stamp-cache contract.** Phase 3 added `want_vals` to
   `stamp_mound_loop` (`src/pasture_3d_brush_raster.cpp`), which returns `out["clipped"] = has_clip`;
   `pasture3d_mound.gd` and `pasture3d_plow.gd` store the stamp cache **only when `clipped` is false**
   and `_stamp_cache.erase(path.get_instance_id())` otherwise. That is right: a clipped grid is the
   NaN-outside-clip grid of §2.3 and must never be cached, and a partial grid must invalidate any
   stored full one. Both §2.3 implementations remain compatible — widening the clip rect leaves
   `has_clip` meaningful, and disabling the clip when a field modifier is present makes `has_clip`
   false so the cache simply starts serving. **Whichever is chosen, `has_clip` must keep meaning "this
   grid is not a complete footprint".** Do not repurpose the flag. Consequence worth stating in the
   §2.5 gate: cache replay only benefits unclipped bakes.
4. **§3.4's fix must revert a band-aid.** Phase 4 changed `_compute_stamp_key` to
   `global_transform if is_inside_tree() else transform`. That silences the detached-node error but
   does not stop the detached bake: `_tools_on_owner` still returns `[self]` and the hole of §3.4 is
   still punched — now with no error to notice it by — and the same brush computes a *different* stamp
   key detached vs attached. Once §3.4's timer cancellation and `is_inside_tree()` guard land, the
   ternary is unreachable and must revert to plain `global_transform`.

**New items folded in**

5. **New §6.4 instance.** Phase 2's other guard,
   `m != null and "material" in m and m.material != null and m.material.has_method("set_seed_surface")`,
   is a four-deep inline capability test in a generic loop — the same shape §6.4 catalogues. Fold it
   into the `Pasture3DNode` protocol there (§6.4 bullet 4).
6. **DLA docstring is now false.** `Pasture3DReliefDLA._mark_stale()` lost its `if _stale: return`
   early-out while its three modifier siblings kept theirs, but the docstring above it still describes
   that early-out and still claims it "Mirrors Pasture3DNodeErosion.set_stale". Listed under §7.2.
7. **Gate location.** This document's gate sections say `project/bench/` (185 gates). A second tier
   now exists at `project/tests/` with a `GdTest` runner, and the rebake-loop work put its four gates
   there (`project/tests/unit/test_brush_rebake_loops.gd`). New gates below may land in either tier;
   put behaviour-level assertions with named criteria in `project/tests/` and measurement gates in
   `project/bench/`. The control-that-fails rule applies to both.

Unaffected: P1 in its entirety, §2.1, §2.2, §2.4, §3.1, §3.5, §3.6, §4.2-§4.4, all of P5, §6.1-§6.3,
§6.5, §6.6. Phase 1's claim that `update_configuration_warnings()` replaces the removed `changed`
emission checks out — 8 call sites in `terrain_brush.gd`, including one that names the modifier.

---

## P1 — The GPU path silently disagrees with the CPU path

> **STATUS: LANDED 2026-09-03.** 1.1-1.5 are implemented and 1.6's gate passes with every control live
> (`project/bench/GraphGpuParityGate.tscn`, criteria G-K). Two things changed along the way and are
> recorded in place: 1.2's fix needed a plan-execution change this document did not anticipate, and 1.4's
> parity criterion turned out to be blocked by a separate CPU defect, now filed as 2.6.

Four independent defects, one symptom: **the same graph produces different terrain either side of
`graph_gpu_threshold()`**, with no warning. They are grouped because they share a single gate
(§1.5) and because three of the four live in the same dispatch/shader pair, so they would otherwise
be three overlapping edits to `pasture_3d_graph_gpu.cpp`.

### 1.1 Kernel mode `22` is claimed by two ops (**the worst bug in the review**)

`GRAPH_GRID_GLSL` is concatenated into a single `main()` at
[pasture_3d_graph_gpu.cpp:880](src/pasture_3d_graph_gpu.cpp:880). Inside it, mode `22` is handled
**twice**:

- [line 122](src/pasture_3d_graph_gpu.cpp:122) — `if (p.mode == 22)`, the PARTIAL MIN/MAX reduction
  used by Contrast's auto-window. It runs **before the bounds guard** and ends in a bare `return`.
- [line 716](src/pasture_3d_graph_gpu.cpp:716) — `if (p.mode >= 20 && p.mode <= 22)`, the mudslide
  block whose `p.mode == 21` else-branch at [line 812](src/pasture_3d_graph_gpu.cpp:812) is the
  mobile-pool advance.

The mudslide dispatch at [line 1611](src/pasture_3d_graph_gpu.cpp:1611) sets `dm.mode = 22`, so it
lands in the MINMAX branch and can never reach line 812. It arrives with `p.f0 = tan_repose` (≈0.70)
where MINMAX reads a **workgroup count**, so per-workgroup min/max height pairs are written into the
mobile-pool buffer at essentially arbitrary indices. From sweep 1 the height dispatch reads that
corrupted pool and slumps catastrophically.

**Trigger:** any Mudslide node with **no mask wired** (a wired mask already bails to CPU at
[line 1584](src/pasture_3d_graph_gpu.cpp:1584)) at or above `graph_gpu_threshold()` cells.

**Fix.** Do *not* just renumber `22` to a free id — that repeats the mistake with a different
number. The mode id space is currently 28 bare integer literals scattered across an 800-line string
and its dispatch sites, with nothing declaring which are taken. Introduce the enum now, in this
phase, because it is what makes the fix verifiable:

```cpp
enum GraphKernelMode { GKM_EVAL = 0, ... , GKM_MINMAX_PARTIAL = 22, GKM_MUDSLIDE_POOL = 28, ... };
```

Stringify it into the GLSL preamble as `#define GKM_* n` — the shader source is in the same
translation unit, so this costs nothing at runtime — and change every dispatch site and every
shader `if` to name the constant. A duplicate id then fails to compile rather than corrupting a
buffer.

**Landed as:** `enum GraphKernelMode` plus a parallel `GRAPH_KERNEL_MODES[]` name table in
`pasture_3d_graph_gpu.cpp`. `_graph_kernel_defines()` generates the GLSL `#define`s from that table and
prepends them along with `#version 450` (the shader string no longer carries its own), so the shader and
the dispatch sites read one declaration. Enums do not reject duplicate VALUES, so the check is explicit:
`_graph_kernel_defines()` returns the empty string on a collision, naming both modes, and `_ensure_init`
treats that as a compile failure rather than building the shader anyway. The mudslide pool pass is
`GKM_MUDSLIDE_POOL = 28`, and the mudslide branch tests its three modes by name instead of the
`>= 20 && <= 22` range that let the collision in. 24 and 25 are retired ids, not free ones.

> The id space as it stands: shader claims at lines 122 (22), 144 (23), 175 (0), 179 (1), 199 (2),
> 209 (3), 221 (4), 244 (5), 274 (6), 283/286 (7,8), 330 (9), 340 (10), 376 (12,13), 394 (14),
> 406 (15), 452 (16), 505 (18), 575 (17), 629 (11), 644 (19), 661 (26,27), 726 (20), 812 (21/22).
> Free ids therefore start at 24, and 28 is safely clear.

### 1.2 The GPU ignores every wired scalar parameter port

`Pasture3DGraphGPU::eval_grid` reads each op's scalars straight out of `p_prog.params*[s]` — e.g.
[line 1533](src/pasture_3d_graph_gpu.cpp:1533) `d.f0 = p_prog.params[s];` — and **never applies the
driven-parameter override tables**. The CPU resolves them into `P[16]` at
[pasture_3d_graph_ops.cpp:596-630](src/pasture_3d_graph_ops.cpp:596) for both the in-slot table
(`pmap0..3`) and the overflow table (`pdrv_node/param/src`). `grep -n "pmap\|pdrv"
src/pasture_3d_graph_gpu.cpp` returns **nothing**.

`native_supported()` explicitly *permits* mapped param ports
([pasture3d_terrain_graph.gd:1839-1859](project/addons/pasture_3d/graph/pasture3d_terrain_graph.gd:1839)),
and `eval_grid`'s only refusal is the **output-channel** guard at lines 1058-1077 — a different
thing. So nothing stops a param-driven graph reaching the GPU.

**Trigger:** wire a `Const 120.0` into a FloodingUniformLevel's `water_level` port. At 128² the CPU
runs and floods to 120 m; at 512² the GPU floods to whatever the inspector was left at. Same for
Noise amplitude, Falloff strength/radius, Contrast amount, Terrace height, DistanceTransform
threshold, ExpandShrink radius, RelativeElevation radius, SmoothFill radius/k, RecastCliff
talus/amplitude, WarpDownslope amount, Gavoronoise amplitude/frequency, Mudslide amount. For ports
0-3 it is worse: the GPU sees a valid `in*` source and binds that constant buffer **as a grid
input** to the op.

**Fix — two options, and take the first.**

1. **Resolve the overrides before dispatch.** Factor the CPU's `P[16]` resolution out of
   `graph_eval_grid_core` into a shared `resolve_op_params(prog, s, P, PH)` and call it from
   `eval_grid` for each op. This is the correct fix and is not large — the resolution is ~35 lines
   and has no CPU-specific state.
2. Refuse in `native_supported()` when any param port is wired. **Rejected as the primary fix**: it
   silently drops large graphs to the CPU path, which is the performance cliff the GPU exists to
   avoid, and it makes the GPU quietly less capable than the CPU forever.

Land option 1. Keep a `#ifdef`-free assertion that `PH[]` is fully consumed, so a future op that
adds a param slot cannot forget.

**Landed as:** `graph_resolve_op_params(prog, slot, P, PH, fetch)` in `pasture_3d_graph_ops.{h,cpp}`,
called by both evaluators; the CPU's open-coded walk is gone.

**One thing this document did not anticipate.** A driven parameter is cell 0 of another slot's grid, and on
the GPU that grid does not exist at plan-build time — the whole plan was built first and executed second,
so there was nothing to read. `eval_grid` now executes in pieces: `run_pending()` builds uniform sets for
the dispatches added since the last flush, runs them, and syncs. Slots are built in topological order, so
everything a driven parameter can read is already in the plan by the time it is needed. The cost is one
submit/sync per driven-parameter slot; a graph with no driven parameters still runs exactly one list, as
before. The fetch callback refuses any channel above 0 rather than serving channel 0's value, because the
plan holds one buffer per slot and the channels guard at the top of `eval_grid` is what makes that safe —
if that guard is ever weakened this fails the fetch instead of quietly answering a different question.

### 1.3 The hydraulic solver's phase 0 races itself

[graph_solver_hydraulic.glsl:53](src/shaders/graph_solver_hydraulic.glsl:53) onward mutates
`water`, `height`, `flow_accum` and `sediment` **in place, in the same dispatch** whose neighbour
reads consume those same arrays, with no barrier:

| Write | Line | Read back by |
|---|---|---|
| `water[i] += p.rain_rate` | 53 | `total_alt - (nh + water[ni])`, lines 71-73 and per direction |
| `flow_accum[i] += p.rain_rate` | 54 | the same neighbour tests |
| `height[i] -= erode_amt` / `+= dep_amt` | 136, 141 | `float nh = height[ni]` |
| `water[i] = w_c - flow_out` | 146 | as above |
| `sediment[i] = sed_c` | 169 | as above |

Whether a neighbour's rain and outflow have landed yet is **undefined**, so `diff` is perturbed by
up to `rain_rate + flow_out` per neighbour. Two runs of the same graph, same seed, same grid return
different heightfields — and neither reproduces `erosion_hydraulic_solve`, which the header claims
matches the GDScript oracle to 2e-6 m.

**Fix.** Adopt the ping-pong the flux buffers already use: phase 0 reads a pass-start snapshot and
**stages** its height/water/sediment edits into `next_*`, with the swap at the end of the pass. The
CPU solver at [pasture_3d_erosion_hydraulic.cpp:156-165](src/pasture_3d_erosion_hydraulic.cpp:156)
is already written this way and is the reference.

> Note `flow_accum` is written cross-cell in the CPU gather too (`flow_accum[ni] += moved_w`), so it
> is not a pure snapshot there either. Match the CPU's behaviour for that one array specifically;
> the other three must become snapshot-read.

**Landed as:** three new SSBOs at bindings 6-8 (`next_height`, `next_water`, `next_sediment`). Phase 0
reads the live arrays as a pass-start snapshot and writes only `next_*`; phase 1 gathers the flux and folds
`next_*` back. `flow_accum` keeps its in-place own-index add, as the note requires. Rain is folded into the
READ (`water[i] + rain_rate`, and the same for each neighbour under its existing finiteness guard) rather
than written back, which gives every neighbour the post-rain level the CPU's separate rain pass produces
without paying for a third dispatch. Gate criterion I is the proof: five GPU solves of the same input are
now bit-identical, and its control shows the solver is not simply doing nothing.

### 1.4 The GPU hoists the sediment share out of the neighbour loop

[graph_solver_hydraulic.glsl:149](src/shaders/graph_solver_hydraulic.glsl:149) computes
`float s_scale = sed_c / max(w_c, 1e-6);` **once**, then each of the four unrolled branches does
`fs.x = fw.x * s_scale; sed_c = max(sed_c - fs.x, 0.0);` — the depletion never feeds back into
`s_scale`. The CPU recomputes the share inside the loop against the progressively depleted pool.

**Consequence:** any cell with two or more downhill neighbours — the common case on a real slope —
exports strictly more sediment on the GPU. For four equal neighbours the GPU exports
`sed_c·flow_out/w_c` in full while the CPU exports a geometrically decaying series. Visibly
different deposition fans at 128² vs 512².

**Fix.** Move `s_scale` inside the loop, recomputed from the current `sed_c`. One line.

**Landed**, as `fs.x = sed_c * (fw.x / w_den)` per direction — the division rather than a hoisted
reciprocal, so it matches the CPU's `sed_c * (moved_w / max(w_c, 1e-6))` to the rounding.

**But it has no parity criterion yet, and that is 2.6's fault, not this fix's.** The obvious gate — GPU vs
CPU on the sediment channel — cannot pass while the CPU clobbers inbound sediment (2.6): the amount the CPU
loses depends on raster order, and a gather cannot reproduce an order-dependent loss. Gate criterion J
therefore compares `height` and `flow` (which do match) and says in the source why `sediment` is excluded.
When 2.6 lands, add `sediment` back to that list — that is the criterion this fix deserves.

### 1.5 Blend's NaN mask (lower confidence — verify before fixing)

[pasture_3d_graph_ops.cpp:690](src/pasture_3d_graph_ops.cpp:690) does
`std::clamp((double)gc[i], 0.0, 1.0)`, which returns **NaN** for a NaN mask (neither comparison is
true), so the cell becomes a hole. The GPU at
[pasture_3d_graph_gpu.cpp:195](src/pasture_3d_graph_gpu.cpp:195) guards `if (!isnan(mv))` and leaves
`r` **fully blended**. NaN is the brush-loop mask value and survives Smooth, Terrace and the
morphology ops, so a NaN-carrying mask is reachable.

**DECIDED AND LANDED: a non-finite mask cell reads as 1.0 — "no opinion", the same answer an unwired port
gives.** The GPU's behaviour was ratified, not the CPU's, and the reasoning is written into
`PASTURE3D_NODE_VOCABULARY.md` under "mask": propagating NaN is correct for a HEIGHT grid, where NaN means
"no data" and every op forwards it, and wrong for a WEIGHT grid, where the question is how much of an op to
apply and a cell with no answer should not decide the terrain is missing. All three paths implement it
(`pasture_3d_graph_ops.cpp` guards with `std::isfinite`, `pasture3d_graph_node_blend.gd` with `is_finite`,
the shader with `!isnan && !isinf`). Gate criterion K carries the fixture and asserts no holes.

The review initially called this a three-way split including GDScript; **that half was refuted** —
Godot's `clampf` uses the same three-way comparison form, so `clampf(NAN,0,1)` is NaN and GDScript
agrees with the native CPU. It is a **two-way CPU-vs-GPU divergence**.

**Before fixing, decide which answer is correct** — that is a design question, not a bug fix. A NaN
mask cell most plausibly means "no opinion here", which argues for the GPU's behaviour (leave the
blend alone), not the CPU's (punch a hole). Whichever is chosen, state it in
`PASTURE3D_NODE_VOCABULARY.md` and make all three paths match.

### 1.6 Gate — `GraphGpuParityGate` (extended; PASSES with live controls)

The existing `project/bench/GraphGpuParityGate.gd` did not catch any of §1.1–§1.4, so extending it
requires proving the extension can fail:

| Criterion | Control that must fail |
|---|---|
| Mudslide at 512² matches Mudslide at 128² within tolerance | Revert §1.1 → the 512² field diverges grossly. **Must be run and seen to fail before the fix lands.** |
| A graph with a `Const` wired into a param port gives the same field at 128² and 512² | Revert §1.2 → the 512² field uses the inspector default. |
| Two consecutive GPU hydraulic solves of the same graph are bit-identical | Revert §1.3 → they differ run to run. This is the only criterion that fails *without* a CPU comparison. |
| GPU vs CPU hydraulic deposition on a slope with ≥2 downhill neighbours | Revert §1.4 → GPU over-exports. |

**As landed**, criteria G-K in `project/bench/GraphGpuParityGate.gd`. The gate calls
`Pasture3DUtil.graph_eval_grid_gpu` and `erosion_hydraulic_solve_grid_gpu` directly, which is what the
paragraph below demands and what makes a green result mean anything. Two fixture lessons paid for in the
first run: the mudslide criterion measured nothing until the talus angle was dropped BELOW the fixture's
own slope (at 25 degrees on a ~24 degree ramp the solver correctly does nothing, and the parity check was
comparing two unchanged fields), and the hydraulic criterion needs a DIAGONAL ramp, because on an
axis-aligned one every cell has a single downhill neighbour and 1.4's hoist is invisible.

Force the GPU path with `graph_gpu_threshold = 1`, and the CPU path with `0`, rather than relying on
grid size. **A direct `graph_eval_grid_gpu` call is the only thing that proves the GPU route** — an
unsupported op drops the *whole* graph to CPU, so a gate that merely evaluates a large graph may be
measuring the CPU and reporting green.

---

## P2 — The native CPU path produces wrong output

Independent of P1. Grouped because all four live in the native rasteriser/evaluator and share the
"native disagrees with the GDScript oracle" gate shape.

### 2.1 Six ops read their mask from the wrong port

`in0..in3` are **strictly port-indexed** —
[pasture3d_terrain_graph.gd:1115](project/addons/pasture_3d/graph/pasture3d_terrain_graph.gd:1115)
`in1.append(int(slot_of[s1]) if s1 >= 0 else -1)`. Six native ops read their secondary grid from
`in1`, but the GDScript node declares it on port 2 or 3:

| Op | `pasture_3d_graph_ops.cpp` | Node's ports | Real grid port | `in1` actually is |
|---|---|---|---|---|
| Contrast | [837](src/pasture_3d_graph_ops.cpp:837) | `["in","amount","mask"]` | 2 | scalar `amount` |
| Falloff | [828](src/pasture_3d_graph_ops.cpp:828) | `["in","strength","radius","noise"]` | 3 | scalar `strength` |
| SmoothFill | [880](src/pasture_3d_graph_ops.cpp:880) | `["in","radius","k","mask"]` | 3 | scalar `radius` |
| RecastCliff | [891](src/pasture_3d_graph_ops.cpp:891) | `["in","talus","amplitude","mask"]` | 3 | scalar `talus` |
| WarpDownslope | [900](src/pasture_3d_graph_ops.cpp:900) | `["in","amount","mask"]` | 2 | scalar `amount` |
| ExpandShrink | [865](src/pasture_3d_graph_ops.cpp:865) | `["in","radius","amount"]` | *none* | scalar `radius` |
| Mudslide | [922](src/pasture_3d_graph_ops.cpp:922) | mask genuinely on port 1 | 1 | **correct** |

**Both halves are wrong at once.** Wire a Falloff into Contrast's `mask`: the native path ignores it
and shapes the whole grid at full strength. Wire a `Const 0.3` into Contrast's `amount`: the native
path *also* uses that constant grid as a per-cell mask, cutting the shaping to 30% everywhere.
`native_supported()` does not refuse these graphs, and the GPU mirrors the same wrong index at
`pasture_3d_graph_gpu.cpp` lines 1238, 1279, 1418, 1466, 1487 and 1516 — including
`d.f7 = (in1[s] >= 0)` as its "is a mask wired" flag.

ExpandShrink is a variant, not a dropped mask: it has no mask port, so port 2 is a grid-valued
`amount` read as a scalar, and passing `in1` (radius) as `msk_arr` is still a mismatch.

**Fix.** Read each op's secondary grid from the port the node actually declares. **Do not hand-patch
six indices** — that is the shape of the bug. Emit the resolved grid-port index into the compiled
program from the node's own port list, so the native side reads `in[grid_port[s]]` rather than a
hardcoded `in1`. This is a partial, contained down-payment on P6 §6.1 and is worth taking here
because it is what makes the fix stick.

### 2.2 Splat paints holes and navigation bits where no control map exists

[pasture_3d_brush_raster.cpp:2517](src/pasture_3d_brush_raster.cpp:2517) uses `get_control`'s
`UINT32_MAX` "no data" sentinel as though it were a real control word:

```cpp
const uint32_t cur = get_control(pos);
const uint8_t base_id = preserve_base ? get_base(cur) : (uint8_t)material;
const uint32_t ctrl = enc_base(base_id) | ... | (cur & 0x6);
```

`get_control` returns `0xFFFFFFFF` whenever `get_pixel` yields `COLOR_NAN`
([pasture_3d_data.h:559-562](src/pasture_3d_data.h:559)) — reachable when the region exists but its
control map was never created, when the region is deleted, and for cells outside any region. Then
`get_base(0xFFFFFFFF)` is **31** and `cur & 0x6` is the **hole bit | nav bit**. Every painted cell
becomes a terrain hole with base texture 31 and navigation on; because `get_height` returns NAN for
a hole, those cells then read as no-data.

The sibling `stamp_road_surface_control` reads the same word at
[2566](src/pasture_3d_brush_raster.cpp:2566) and guards exactly this at
[2574](src/pasture_3d_brush_raster.cpp:2574) with `if (cur == UINT32_MAX) { cur = 0u; }`, above a
comment describing the identical failure — before its own `(cur & 0x6)` at 2579. Splat never got the
same normalisation.

**Fix.** Add the same normalisation. Then **hoist it into `get_control`'s callers as a shared
helper** (`control_or_default(pos)`) — there are now two known sites and the guard has already been
missed once. Applies whether `preserve_base` is true or false, since `cur & 0x6` is unconditional.

### 2.3 Field modifiers see NaN outside the clip rect

The pre-pass at [lines 1370-1382](src/pasture_3d_brush_raster.cpp:1370) `continue`s on
`z < cz0 || z >= cz1` and `x < cx0 || x >= cx1`, leaving `amp` at its NAN initialisation
([1341](src/pasture_3d_brush_raster.cpp:1341)); line 1514 materialises `vals` as NaN there. The
FIELD dispatch at [1520](src/pasture_3d_brush_raster.cpp:1520) then runs SMOOTH / EROSION / GRAPH
over that grid.

`erosion_solve` turns every non-finite cell into a fixed outlet at `zmin - 1` with `boundary = 1`
([pasture_3d_erosion.cpp:272-280](src/pasture_3d_erosion.cpp:272)), so **the drainage network is cut
off at the dirty-rect edge**: a mound whose water flowed across the whole loop now drains straight
out at the rect boundary, leaving a permanent seam on the tile-snapped clip edge that a full bake
does not have. `nan_blur` (SMOOTH) has the same problem in milder form — it cannot average across
the boundary.

**The `modifier_margin` skirt does not cover this**, and that is the important part: margin cells are
only materialised inside the `signed_d <= 0.0` branch, which is itself reached only *after* both
clip `continue`s. The skirt is clipped away exactly when it is needed.

**Fix — at the stack boundary, not per modifier.** This is the same lesson the margin skirt already
encodes. When any modifier in the stack answers `needs_grid()`, the clip rect handed to the pre-pass
must be **widened by the stack's margin** before the `continue`s are evaluated, and narrowed back to
the true clip only when writing into the layer. Two consequences to honour:

- `_refresh_owner_rect` selects the dirty-rect path purely on `_full_dirty` / `_dirty_splines`
  ([pasture3d_terrain_brush.gd:873-875](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:873));
  `needs_grid()` appears in the file only at 4059, inside stack compilation. The decision needs the
  stack's answer, so it must move after — or query — the compile.
- A large enough margin makes a "dirty rect" the whole footprint. That is correct and acceptable:
  a field modifier is a global operator and pretending otherwise is what produced the seam. Log at
  `log_bake_timing` when the margin swallows the rect, so the cost is visible rather than mysterious.

### 2.4 Two smaller native defects, same files

- **`stamp_plow_loop` indexes `p_src_data` unvalidated.**
  [line 2377](src/pasture_3d_brush_raster.cpp:2377) reads `p_src_data[py * data_w + px]` guarded only
  by `is_empty() || data_w <= 0 || data_h <= 0` — never that the array is `data_w * data_h` long.
  godot-cpp's `operator[]` returns `nullptr` out of range and dereferences it, so this is a null-deref
  crash of the editor. **Severity is "hostile or buggy caller only"**: there is no production GDScript
  caller (no `pasture3d_plow.gd` exists; the only in-tree caller is the dev tool
  `tools/gpu_spike/ab_mound_cli.gd:171`, which passes a matching size). Fix anyway — it is a public
  binding, and its three siblings (lines 2140, 2298, 2540) all validate.
- **`isnan` vs `is_finite` against the oracle.** [line 1514](src/pasture_3d_brush_raster.cpp:1514)
  tests `std::isnan(amp[k])` where the GDScript twin it is declared bitwise-identical to tests
  `is_finite`
  ([pasture3d_terrain_brush.gd:4331-4333](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:4331)).
  A ±INF contribution is a no-write in the oracle and an infinite height natively — which then
  propagates through `nan_blur` (INF is not NaN, so it is *averaged into its neighbours*) into the
  layer. Same mismatch at 1436, 1464 and 1563. Make the native side test `std::isfinite`.

### 2.6 The hydraulic solver's sediment scatter is clobbered by an assignment (**found while gating P1**)

`pasture_3d_erosion_hydraulic.cpp`'s routing loop scatters into its neighbours —
`next_water[ni] += moved_w`, `next_sediment[ni] += moved_s` — and then ends the cell with

```cpp
next_sediment[i] = (float)sed_c;   // ASSIGNMENT
```

while the sibling line for water four lines above is `next_water[i] = next_water[i] - flow_out`, an
accumulation. So a cell that routes **discards every grain scattered into it by the neighbours the raster
order happened to reach first**, and keeps the ones from neighbours reached later. What is lost is a
function of iteration order, not of the terrain.

`pasture3d_graph_node_dev_erosion_hydraulic.gd:273` has the identical assignment, so the native kernel and
the GDScript oracle agree with each other — which is why every existing parity gate is green and how this
survived. The GPU cannot agree: its phase-1 gather adds all four inbound contributions, and no gather can
reproduce an order-dependent loss. Measured on a 48x32 diagonal ramp, the normalised sediment channel
differs by **0.61 after a single iteration** while height differs by 2e-5 — structural, visible from pass
one, not accumulated drift.

**This is why 1.4 has no parity criterion.** It is filed here rather than in P1 because the defect is in
the CPU reference, and because deciding it changes what the solver MEANS: does a cell's outbound sediment
replace its inbound, or add to it? The GPU's answer (add) conserves material; the CPU's does not.

**Fix.** `next_sediment[i] += (float)sed_c` in the native kernel and `next_sediment[i] += sed_c` in the
GDScript oracle, together, in one change. Then add `sediment` back to gate criterion J's channel list in
`GraphGpuParityGate.gd` — that is the control: it fails today and must pass after.

**Do not fix one and not the other.** The two are the parity pair, and splitting them turns a shared defect
into a divergence.

### 2.5 Gate — `GraphCppParityGate` + `BrushStackGate`

| Criterion | Control that must fail |
|---|---|
| Contrast with a Falloff on `mask` matches the GDScript oracle | Revert §2.1 → native ignores the mask. Also assert the *inverse*: a `Const` on `amount` must **not** act as a mask. |
| Splat over a region with no control map sets no hole and no nav bit | Revert §2.2 → every cell is a hole. Build the fixture by creating a region and *not* creating its control map. |
| A one-point spline drag on a Mound with an Erosion modifier matches the full bake inside the rect | Revert §2.3 → a seam at the tile-snapped clip edge. **This is the criterion most likely to be written so it cannot fail** — assert on the *height field along the clip boundary*, not on a whole-grid mean, which averages the seam away. |
| A relief op producing ±INF writes nothing, matching the oracle | Revert §2.4 → an infinite height, then INF smeared by `nan_blur`. |

---

## P3 — The deferred bake driver hangs, freezes, or damages a neighbour

Five defects in one subsystem — the `_bake_deferred` / `_solve_on_worker` driver in
`pasture3d_terrain_brush.gd`. Grouped because they interlock: §3.2's abort is what makes §3.3's flag
stick, and both are reached through the same teardown path. **Fix them as one change**; fixing any
one alone leaves the others reachable.

### 3.1 `graph.evaluate()` runs on a worker thread and races the editor

[line 1246](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:1246) — `_graph_solve_one`
calls `Pasture3DTerrainGraph.evaluate()` on a `WorkerThreadPool` thread. `evaluate()` **mutates the
shared graph resource** on both routes: `store_cache` at
[terrain_graph.gd:532](project/addons/pasture_3d/graph/pasture3d_terrain_graph.gd:532),
`_global_access_tick += 1` at 544, `node._last_access_tick` at 566, `store_cache` at 681 and
`_evict_cache_if_needed()` at 682.

The driver exists precisely so the main thread keeps running. With the Terrain Graph dock open on the
same resource, the user adding or deleting a node mutates `graph.nodes` / `graph.connections` on the
main thread underneath the worker's `for ni in order` loop — concurrent write/read of the same
Array/Dictionary/PackedFloat32Array refcounts. Out-of-range index, corrupted cache grid, or an editor
crash. Reachable without the dock open too, whenever a second brush bakes synchronously against a
graph modifier referencing the same resource.

**Fix.** Adopt the contract `graph_editor.gd` already uses at
[lines 2019-2022](project/addons/pasture_3d/src/graph_editor.gd:2019): **compile on the main thread,
solve on the worker.** Capture the compiled program and the input grid before dispatch; the worker
body touches only the stateless native entry points (`graph_eval_grid` / `graph_eval_grid_taps`) and
marshals back with `call_deferred`. No `Pasture3DTerrainGraph` method may be called off the main
thread — assert `Thread::is_main_thread()` at the top of `evaluate()` so the next such call fails
loudly instead of racing.

### 3.2 `_join_worker` clears `_task_id` while the coroutine is awaiting

`_solve_on_worker` polls at [lines 349-358](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:349):
`while not WorkerThreadPool.is_task_completed(_task_id): ... await get_tree().process_frame`.
`_join_worker` ([384](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:384)) is called
from `NOTIFICATION_EXIT_TREE` and PREDELETE, and ends with `_task_id = -1`. Nothing in the poll loop
tests `_task_id != -1`.

Two outcomes:
- **Reparent in the Scene dock** (EXIT_TREE then ENTER_TREE in one frame) → the resumed coroutine
  calls `is_task_completed(-1)`, which errors and returns false, **forever**: one error per frame,
  and `_solve_on_worker` never returns.
- **Node stays detached** → `get_tree()` returns null and the coroutine dies outright.

**Fix.** Guard the poll loop on `_task_id != -1` and break out into the cancelled path. Have
`_join_worker` set an explicit `_aborted` state rather than only clearing the id, so the coroutine
can tell "joined" from "never started".

### 3.3 `_erosion_running` is never cleared on teardown

Every write is `= true` at 1074 and `= false` at 1101, 1121 and 1130 — **all inside
`_bake_deferred`**. Neither `_join_worker` nor the EXIT_TREE / PREDELETE branches (836-848) touch it.
`_on_refresh_timer` guards at [line 861](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:861):
`if _erosion_running: _arm_refresh_timer(); return`.

So either abort in §3.2 leaves the flag set with no owner to clear it. Every subsequent timer tick
re-arms and returns — a 0.1 s loop that never bakes. **The brush silently stops responding to spline
drags, transform moves and inspector edits for the rest of the editor session**, and
`_wants_deferred_bake()` also refuses at 1024, so the only surviving path is a manual Refresh that now
freezes the editor.

**Fix.** Clear it in `_join_worker` and in the teardown notifications. Better: make it
`_deferred_owner: int` (the task id, or -1) rather than a bare bool, so "running" is derivable from
the thing that actually owns the run and cannot desynchronise from it.

**Raised in force by the landed rebake-loop fix.** `_commit_modifier_caches` now reads
`if reseeded and not _erosion_running and not _growth_defer` before scheduling a refresh. Both flags
are cleared only inside `_bake_deferred`, so a stuck flag now also stops DLA seed surfaces
re-converging — the abort no longer costs one behaviour, it costs two. **This section is a
prerequisite for that guard's correctness.** `_growth_defer` needs the same owner-derived treatment,
not just the same clearing.

### 3.4 The refresh timer survives EXIT_TREE and bakes on a detached node

`_arm_refresh_timer` guards *arming* with `if not is_inside_tree(): return`
([836-846](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:836)) but creates a plain
`get_tree().create_timer(REFRESH_DELAY)` that nothing cancels. The EXIT_TREE branch does
`remove_from_group`, `_join_worker()` and `_clear_mask_preview()` — never `_timer`.

`_on_refresh_timer`'s only relevant guard is `if not Engine.is_editor_hint() or not is_configured():
return`, and `is_configured()` ([569](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:569))
is just `is_instance_valid(terrain) and terrain.data != null` — **no tree check** — so a detached node
passes. `_tools_on_owner` ([1681-1689](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:1681))
then returns only `[self]`, because its group scan is wrapped in `if is_inside_tree():`.

**Result:** `clear_layer_in_area` wipes the recorded `_last_paint_aabb` box and **no layer-mate is
repainted** — a permanent hole punched in a neighbouring Mound sharing that layer. Delete a brush
within 100 ms of editing a spline and its neighbour is damaged. Additionally
`_spline_footprint_aabb` reading `global_transform` on detached `Path3D` children yields an identity
transform, adding a stray box at the world origin.

**A second consequence, from the guard ordering.** `_on_refresh_timer` clears `_dirty` at 864 and
snapshots-and-clears `_full_dirty` / `_dirty_splines` / `_moved_node` at 865-871 — **before** the
`is_configured()` check at 873. So even on the paths where the guard *does* reject the tick, the
queued dirty state has already been discarded: the edit that armed the timer is silently forgotten
rather than deferred. Any fix must move the snapshot below every guard.

**Fix.** Cancel the timer in the EXIT_TREE branch, **and** add `is_inside_tree()` to
`_on_refresh_timer`'s guard, **and** move the dirty-state snapshot below the guards. All three: the
first is the intent, the second is the invariant the bake actually depends on, the third is what
stops a rejected tick eating the user's edit — and §3.5 shows guards at this layer get missed.

**And revert the band-aid.** `_compute_stamp_key` currently reads
`global_transform if is_inside_tree() else transform` — added to silence the detached-node error this
same defect produces. It does not prevent the detached bake, and it makes one brush compute two
different stamp keys depending on tree state. Once the three fixes above land the branch is
unreachable; restore plain `global_transform` in the same change, so the key stays a function of the
brush and not of when the timer happened to fire.

### 3.5 Cancel during the graph phase is discarded, then freezes the editor

[lines 1106-1115](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:1106):

```gdscript
if not pending_graph.is_empty():
    var ok_graph := await _solve_graph_pending(pending_graph)
    if ok_graph:
        for st ...  # store_cache
```

No `else`, no `return`, no message. Compare the growth phase immediately above (1100-1104), which
does `_erosion_running = false; _commit_deferred_undo(...); return` plus a printed explanation, and
the erosion tail (1130-1136), which prints "erosion cancelled".

Then `_solve_erosion_pending` resets `_cancel = false` at ~1277, **erasing the cancel**. So pressing
Cancel during the graph phase: nothing is stored, the multi-minute erosion solve the user was
cancelling runs to completion, and the final `p_bake.call()` re-bakes with `_graph_defer` already
cleared at 1091 and the cache still empty — so `_apply_graph_step`'s deferred branch is skipped and
**the whole graph is evaluated on the main thread**, exactly the freeze Cancel was meant to abandon,
with nothing said to the user.

**Fix.** Return on `not ok_graph` with the same shape as the growth phase. Move the `_cancel = false`
reset to the *top of the driver*, not into phase C — a phase must never clear a cancel it did not set.

### 3.6 The erosion `defer` flag is written to one dict and read from another

`_compile_modifiers` builds two parallel dicts per modifier: `blk` (consumed by C++ via `out["list"]`)
and `step` (consumed by `_run_modifier_stack` via `out["gd"]`).
[Line 4075](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:4075) sets
`blk["defer"] = _erosion_suppress or (_erosion_defer and bool(blk["frozen"]))`, but the only keys ever
written into `step` are `out`, `capture`, `sel_base`, `sel_count`. `_apply_erosion_step` at ~4791
reads `p_step.get("defer", false)` — **always false**.

The GDScript path is reachable: `force_gdscript_raster` is an `@export`
([97](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:97)), and
`_stack_forces_gdscript()` (3630) forces it for a graph with an unsupported op or a road grader
alongside any other modifier. On that path the frozen erosion solves **synchronously on the main
thread** and `_pending_erosion` stays empty so phase C is skipped. Separately,
`bake_without_erosion()`'s `_erosion_suppress` reaches only `blk`, so "Clear Simulation On All
Brushes" clears the caches and then **re-erodes anyway**.

`_apply_graph_step` at 4637 has the member fallback (`or _graph_defer`); the erosion step has none.

**Fix.** Write `defer` into `step` as well. Then delete the divergence: `blk` and `step` should be
built from one dict with a projection, not two hand-maintained parallel dicts — this is P6 §6.4 and
the immediate fix should be written so it does not obstruct it.

> Related, and worth folding in: `_worker_body`
> ([368](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:368)) only tests `_cancel`
> *inside* `while not p_chunk.call(st):`, and all three brush chunk callables return `true` on their
> first call — so the body never runs and `_cancel` is never read. Results are not wrong (the driver
> still honours `_cancel` via `return not _cancel`), but Cancel cannot abandon **between** grids: the
> user waits out every remaining grid and then gets nothing. The header comment at ~343 ("Cancel still
> lands on a chunk boundary") is false for the brush's own callables. Move the `_cancel` test to the
> top of the `for` body.

### 3.7 Gate — `BrushDeferredDriverGate` (new)

Headless gates **cannot see scheduling** — `_schedule_refresh` is editor-only — so assert on the
returned decision, not on `_full_dirty`. Criteria:

| Criterion | Control that must fail |
|---|---|
| `evaluate()` called off the main thread aborts | Revert §3.1 → it proceeds and mutates. Assert via the new `Thread::is_main_thread()` check, which is testable headless. |
| After a simulated EXIT_TREE mid-solve, `_erosion_running` is false and a later refresh bakes | Revert §3.3 → the second refresh never bakes. |
| Cancel during the graph phase returns without running the erosion phase | Revert §3.5 → the erosion solve runs to completion. |
| On the forced-GDScript path, a frozen erosion step defers | Revert §3.6 → it solves inline. Force with `force_gdscript_raster = true`. |

**`data_directory` is an editor risk**: a gate cannot corrupt demo data headless, and a clean
`git status` after a run proves nothing. Point these gates at a scratch directory explicitly.

---

## P4 — Caches serve data from another node, place, or parameter value

Independent of P1–P3. Grouped because all four are the same failure shape — **a cache key that omits
something the cached value depends on** — and because the last of them is the general fix.

### 4.1 Cache eviction frees nothing and clears every cached node

`_evict_cache_if_needed` frees memory by calling `n.clear_cache()`
([terrain_graph.gd:127](project/addons/pasture_3d/graph/pasture3d_terrain_graph.gd:127)). The base
`clear_cache` ([pasture3d_graph_node.gd:105](project/addons/pasture_3d/graph/pasture3d_graph_node.gd:105))
resets `_cached_grid`, which is exactly what `get_cache_size_bytes()` measures. But **20 solver node
classes override `clear_cache()` and touch only their own private `_cache`** —
`grep -rn "super.clear_cache" project/addons/pasture_3d/graph/` returns **zero hits**.

Since [line 681](project/addons/pasture_3d/graph/pasture3d_terrain_graph.gd:681) calls `store_cache`
for every node in the eval order, solver nodes really do hold a base `_cached_grid` their override
cannot free. So: eviction frees **0 measured bytes**, the
`if get_total_cache_bytes() <= max_cache_bytes: break` never fires, and the loop walks the whole
list. Each override's `emit_changed()` destroys the node's FROZEN solve — the expensive solve the
freeze exists to skip — and **re-enters `_on_node_changed` mid-eviction**, bumping `_revision` and
invalidating the host brush's bake. Every subsequent bake repeats it. The same collision makes the
graph-level `clear_cache()` at line 98 a no-op for exactly the nodes it documents itself as clearing.

The 20: `dla`, `erosion`, `erosion_hydraulic`, `erosion_thermal`, `hydraulic_particle`,
`hydraulic_saleve`, `hydraulic_stream_log`, `lake_flooding`, `stream_extraction`, `mudslide`,
`scree`, plus the `dev_` twins of the first nine.

**Fix.** Every override calls `super.clear_cache()`. Then make it unrepresentable: rename the base
method `clear_cache()` to a `final`-by-convention entry point that calls a `_clear_solver_cache()`
hook, so a subclass overrides the hook and cannot skip the base work. This is the cheapest half of
P6 §6.3 and should land here.

### 4.2 The graph modifier serves another location's grid

The extent key is `"%d,%d,%d,%d" % [roundi(min_x/vs), roundi(min_z/vs), gw, gh]`
([terrain_brush.gd:4150](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:4150)) —
**fields 0/1 are the world origin**. `cache_for`'s fallback
([mod_graph.gd:175](project/addons/pasture_3d/connectors/pasture3d_mod_graph.gd:175)) parses only
`parts[2]` / `parts[3]`:

```gdscript
if g.size() == n and entry.get("gw", gw) == gw and entry.get("gh", gh) == gh:
    _cache[p_extent] = entry
    return entry
```

Verified explicitly: **nothing re-projects by world position.** Entries store only
`{key, grid, gw, gh}` — no world bounds are recorded — and `_resample_grid` is a pure dimension
stretch. The exact-dimension branch does not resample at all, and it **writes the borrowed entry back
under the new key**, so the mistake persists.

Two same-sized loops under one Mound with a FROZEN Graph modifier: loop A caches under `"0,0,200,200"`;
loop B asks for `"640,640,200,200"`, misses, and is handed A's grid. Same for one loop dragged more
than a cell or two. For a pure generator graph the key is `g.content_key()` (4627), which does not
change when the loop moves — so `out_slot["stale"]` is **false** and the user gets no warning.
`Pasture3DNodeErosion.cache_for` is a plain exact `_cache.get(p_extent, {})`; only the graph modifier
does this.

**Fix.** Delete the dimension-only fallback. If the drag-jitter tolerance it was written for
(the comment at ~194 cites "±1..2 cell bounding-box rounding") is genuinely needed, key it on the
**world origin within a tolerance**, and re-project by stored world bounds rather than stretching by
dimension. Store `min_x`, `min_z`, `vs` in the entry so re-projection is possible at all.

### 4.3 Dev node parameter edits never invalidate anything

`_compute_node_inputs_hash`
([722](project/addons/pasture_3d/graph/pasture3d_terrain_graph.gd:722)) builds its signature from
`[gw, gh, rect x/y/w/h, muted, op()]` plus upstream signatures — **no node parameters at all**.
Staleness rides entirely on `_dirty_revision`, bumped only by the base class's
`changed.connect(_on_node_changed_bump_revision)`. The base provides no other invalidation path: no
`_set` override, no `_validate_property`, no `_param_changed` helper.

Eight `[Dev/GD]` node classes declare plain `@export` vars **with no setter**, so they never emit
`changed`: `dev_gavoronoise`, `dev_water_mask`, `dev_mudslide`, `dev_warp_downslope`,
`dev_expand_shrink`, `dev_distance_transform`, `dev_flooding_uniform_level`, `dev_terrain_metrics`.

Add a `[Dev/GD] Gavoronoise`, wire it to Output, bake. Its op is not in `SUPPORTED` so the whole graph
takes the GDScript cached path, and with `input_count() == 0` its key is a constant for that extent.
Change `amplitude`, `seed`, `frequency` or `angle_deg`: no `changed`, no revision bump, no hash
change. **The node serves its first grid forever**, and the host's `_revision` never bumps either, so
nothing even schedules a re-bake.

**Fix.** Give the eight classes setters calling `_param_changed()`, matching their production twins.
Then close the hole underneath: `@export` assignment emits no `Resource.changed` in GDScript, so this
will recur. Add a `GraphNodeParamGate` that reflects over every registered node class, mutates each
`@export` property in place, and asserts `_dirty_revision` moved — a class that forgets a setter then
fails at gate time rather than at bake time.

### 4.4 Two more keys that omit their dependencies

- **The native path stores the output node's cache with an empty `inputs_of`.**
  [terrain_graph.gd:532](project/addons/pasture_3d/graph/pasture3d_terrain_graph.gd:532) passes `{}`
  for both `inputs_of` and `input_ports_of`, so the per-port loop never runs and the key encodes
  **nothing about the graph that produced the grid** — just `hash([gw, gh, rect…, muted, op])`. It
  also stamps `_last_baked_revision`. Today the GDScript path happens to compute a longer array so
  the two keys never collide, but that is a coincidence of array length, not a stated property. The
  live half is the unconditional `{}` for `aux`: solo-preview a multi-output Erosion node on a
  native-supported graph and its five cached channels are replaced with an empty dict, so a later
  cache hit hands downstream `_read_channel` **zeros for every port ≥ 1**. Compare line 681, which
  passes the real maps and `aux.get(ni, {})`. Pass them here too.
- **`erodability_map` edits in place are never noticed.**
  [mod_erosion.gd:73-78](project/addons/pasture_3d/connectors/pasture3d_mod_erosion.gd:73) clears
  `_lut_cache` on *reassignment* but never connects the texture's own `changed`. `_lut()` (241-243)
  short-circuits on any non-empty cache. Assign a `NoiseTexture2D`, then change its frequency or
  reimport the source PNG: the LUT stays as first baked, `to_params()["erodability_lut"]` is
  unchanged so nothing re-bakes and nothing warns. `mod_noise.gd:17-22` and `mod_relief.gd:28-33`
  both connect/disconnect their sub-resource's `changed` to `_touch` — copy that.

> **Also fix here, since it is the same review's finding and the same file:** the 20 solver nodes of
> §4.1 use **four incompatible key rules**. Ten use `hash(gw) ^ (hash(gh) << 1) ^ hash(surface)`;
> `mudslide.gd:217` folds the mask; `erosion_thermal.gd:180` takes a hardness array; and
> `lake_flooding.gd:242` / `stream_extraction.gd:268` use `hash(arr.size()) ^ hash(arr)`, **dropping
> `gw`/`gh` entirely** — so a frozen Lake Flooding cannot tell 512×128 from 128×512. Unify on the
> canonical `_compute_node_inputs_hash` / `_content_sig` the graph already provides.

### 4.5 Gate — `GraphNodeCachingGate` (extend) + `GraphNodeParamGate` (new)

| Criterion | Control that must fail |
|---|---|
| Evicting past `max_cache_bytes` reduces `get_total_cache_bytes()` | Revert §4.1 → it does not move. Assert the *number*, not that the call returned. |
| A frozen solver node's cached grid survives an eviction of an unrelated node | Revert §4.1 → it is destroyed. |
| Two same-sized loops at different origins get different graph grids | Revert §4.2 → identical grids. |
| Every registered node class: mutating each `@export` bumps `_dirty_revision` | Revert §4.3 → the eight dev classes fail. This gate is the general control. |
| Lake Flooding frozen at 512×128 does not serve its 128×512 cache | Revert §4.4 → it does. |

---

## P5 — Editor lifetime, signals and undo

Lower severity: annoyance, leaks and spurious work, not wrong terrain. Independent of P1–P4.

### 5.1 `_bind_nodes` probes a different Callable than it connects

[terrain_graph.gd:139-146](project/addons/pasture_3d/graph/pasture3d_terrain_graph.gd:139) connects
`_on_node_changed.bind(n)` but tests and disconnects the **unbound** `_on_node_changed`. A
`CallableCustomBind` never compares equal to a plain Callable, so `is_connected(...)` is always
false. The `nodes` setter (29-34) runs `_bind_nodes(nodes, false)` then `(nodes, true)` on every
reassignment, so:

- the disconnect branch is **dead** — a removed node stays wired to the graph; and since
  `nodes.find(p_node)` returns -1, `_on_node_changed` leaves `affects_output = true` (155) and
  **unconditionally re-bakes** for a node the graph no longer contains;
- every reassignment re-connects already-connected nodes, which Godot refuses with
  `ERR_INVALID_PARAMETER` — `deserialize_subgraph` calls `add_node` in a loop, so pasting 10 nodes
  emits ~55 errors.

`_bind_frames` (182-189) is symmetric and correct, which is what makes this an outlier rather than a
convention. **Fix:** hold `var cb := _on_node_changed.bind(n)` in a local and use it for
`is_connected` / `connect` / `disconnect`. Separately, make `_on_node_changed` default
`affects_output` to **false** when `n_idx == -1` — that case is provably "changes nothing the bake
would see".

### 5.2 `_init`'s self-capturing lambda (**PLAUSIBLE — verify before claiming a leak**)

[terrain_graph.gd:205](project/addons/pasture_3d/graph/pasture3d_terrain_graph.gd:205) —
`changed.connect(func(): _revision += 1)`. The lambda touches a member, so GDScript wraps it in a
`GDScriptLambdaSelfCallable`, which for a `RefCounted` host holds a strong reference; storing it in
the object's own signal list is a classic cycle, and the graph would never reach refcount 0 — taking
every node's `_cached_grid` with it, bounded only by `max_cache_bytes` (default 256 MB per graph).

**This hinges on Godot engine semantics that could not be proven from this repo's code**, so do not
report it as a confirmed leak. The fix is trivial and correct either way: give the graph a named
`_bump_revision()` method and connect that, exactly as
[pasture3d_graph_node.gd:76-77](project/addons/pasture_3d/graph/pasture3d_graph_node.gd:76) already
does. If someone wants the confirmation, `Performance.get_monitor(OBJECT_COUNT)` across repeated
scene reloads will show it.

### 5.3 A null node in the eval order crashes instead of degrading

`_eval_order`'s ancestor walk ([~1981](project/addons/pasture_3d/graph/pasture3d_terrain_graph.gd:1981))
checks bounds but not null, and `_fold_plan` (~866) then calls `nodes[ni].input_count()` on `null`.
`graph_warnings` explicitly anticipates this state ("Terrain graph node %d is empty (null)"), and both
the root check at 1969 and `native_supported` at ~1820 **do** guard null — so this is an inconsistency
inside one file. Trigger is narrower than "a graph with a null node": the null must be **reachable by
a connection from the output** (a `.tres` whose node script failed to load — a renamed script, or
dev-flag scripts absent from a build). `_eval_order_multi` (1484) has the identical gap.

**Fix.** Null-check in both walks and degrade to the flat zero field `evaluate` already promises.

### 5.4 Three smaller editor defects

- **Delete-nodes undo omits `output_override`.**
  [graph_editor.gd:1844](project/addons/pasture_3d/src/graph_editor.gd:1844) restores `nodes`,
  `connections` and `output_node` but not `output_override`, which `remove_node` shifts
  (terrain_graph.gd:252-253). Solo-preview node 5, delete node 2 (override decrements to 4), Ctrl+Z:
  indices come back but the override stays 4, so `output_index()` returns a **different node** — the
  wrong field is baked and cached as the terrain output, and the canvas soloes the wrong card.
  `_action_set_output` two functions below *does* save and restore it.
- **A shared `Curve3D` silently drops the second spline.**
  [terrain_brush.gd:591](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:591) —
  `CallableCustomBind` equality compares the base callable and the bind **count**, not the bind
  *values*, which is what makes the call idempotent. Ctrl+D a spline child (Godot shares the `Curve3D`
  by default; the brush already warns about this at 530): `_connect_spline(B)` probes
  `is_connected(_schedule_spline_refresh.bind(B))`, which compares equal to A's entry, so **B is never
  connected**. Dragging the shared curve marks only A dirty, and if B sits outside A's dirty box it is
  skipped entirely — B's old stamp stays on the terrain. Key the connection on the instance id rather
  than relying on Callable equality.
- **`_ensure_layer_for` warns and then proceeds.**
  [terrain_brush.gd:2140](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:2140)
  `push_warning`s that the resolved layer has the wrong map type, then returns its id anyway — so a
  height brush writes float heights into a CONTROL layer. Return `-1` (the destructive-fallback path
  the docstring already defines).
- **An inspector lambda is connected in `_init` and never disconnected.**
  [editor_plugin.gd:74](project/addons/pasture_3d/src/editor_plugin.gd:74) —
  `EditorInterface.get_inspector().mouse_entered.connect(func(): mouse_in_main = false)`. `_exit_tree`
  disconnects the two siblings (181, 186) but not this one, and the inspector outlives the plugin, so
  every addon disable/enable or script reload leaves a stale lambda bound to a discarded plugin
  instance. Also note the `focus_entered` connect is in `_init` while its disconnect is in
  `_exit_tree`, so focus handling is dead after the first tree exit — move both to `_enter_tree`.

---

## P6 — The structural debt that caused P1, P2 and P4

**Land last.** Each item below is the general form of a bug already fixed above; doing these first
would rebase every earlier phase, and doing them never means the same bugs return.

### 6.1 The op vocabulary lives in five host-side tables

`Pasture3DGraphNode` subclasses own an op but declare **none** of its wiring. Instead, five tables in
`pasture3d_terrain_graph.gd` restate it, keyed by op string:

| Table | Location | What it states |
|---|---|---|
| `_lower_node_op` | [1246](project/addons/pasture_3d/graph/pasture3d_terrain_graph.gd:1246)+ | 70 literal `op_id = <int>` assignments |
| the cell-path match | 957-984 | the **same** ids restated (1,2,3,4 …), plus mute→3 at 953 |
| `PARAM_PORT_MAP` | 1177-1216 | which ports are scalars |
| `SUPPORTED` | 1793-1800 | which ops may lower natively |
| `NATIVE_OUT_COUNT` | 1682-1686 | multi-output channel counts |

And `enum GraphCellOpType` ([pasture_3d_graph_ops.h:36-90](src/pasture_3d_graph_ops.h:36)) has **no
`BIND_ENUM_CONSTANT`**, so the GDScript side carries 70 hand-typed magic integers.

This is not theoretical debt — **the in-file comments already record three shipped bugs of exactly
this shape**: Crater baking a fixed amplitude (1301-1306), Warp putting `strength` in the noise-*type*
slot (1307-1310), and Curve reading five nonexistent property names and throwing on `bool(null)`
(1315-1320). §2.1 of this document is the fourth. Forgetting a `SUPPORTED` entry is silent (DLA
escaped native lowering for exactly that reason, 1822-1826); forgetting `NATIVE_OUT_COUNT` silently
truncates a multi-output node to channel 0.

**Fix.** Move the declaration to the class that owns the op: each subclass declares
`native_op_id()`, `lower(ctx)`, `param_ports()`, `grid_ports()` and `out_count()`; the host iterates
instead of matching. Bind `GraphCellOpType` so the id is written **once, in C++**. Mute is currently
op `12` at line 1244 and op `3` at 953 — two literals for one concept; pick one.

### 6.2 Nine `Pasture3DGraphGPU` singletons, each with its own RenderingDevice

`grep -c "static Pasture3DGraphGPU s_gpu" src/pasture_3d_graph_gpu.cpp` → **9** (lines 2089, 2102,
2116, 2166, 2212, 2261, 2313, 2360, 2406), each a function-local static. Only line 2116 carries the
comment justifying *one*: "persistent: the local RD + shader compile once across calls."

`_ensure_init_geo` (950) and `_ensure_init_hydraulic` (912) both chain through `_ensure_init` (855),
which calls `create_local_rendering_device()` and compiles the full four-part grid shader. So a scene
touching all seven geo primitives plus hydraulic plus the graph pays **nine** device creations and
nine grid-shader compiles, seven of which are never dispatched — each holding its own VRAM and tearing
down at static-destruction time, after `RenderingServer` may already be gone. The "try GPU above a
threshold, else CPU" routing policy is likewise written out nine times, so a new bail condition is a
nine-site edit.

**Fix.** One `static Pasture3DGraphGPU &graph_gpu()` accessor next to `graph_gpu_threshold()` (2073),
plus one `dispatch_or_cpu(...)` wrapper holding the routing rule. The class is already lazily
initialised and stateless between calls, so nothing else changes.

### 6.3 Twenty solver nodes hand-roll a parallel cache

Beyond §4.1's missing `super()`: `enum Evaluation { LIVE, FROZEN }` plus `_cache` / `_cache_key` /
`_stale` / `_dirty_since_bake` / `_set_stale` / `clear_cache` / `blocks_native` and an identical
hit-miss flow are copy-pasted across 20 files, with the four incompatible key rules of §4.4. Hoist the
whole protocol into `Pasture3DGraphNode` (or a `Pasture3DGraphSolverNode` between it and the leaves),
keyed by the canonical `_compute_node_inputs_hash`. The subclass then supplies only `solve()`.

### 6.4 Three type-switches inside otherwise generic paths

- `_apply_field_step` ([terrain_brush.gd:4466](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:4466))
  dispatches grid modifiers with a hardcoded `if`-chain on `m.op()` — `smooth`/`erosion`/`graph`/`road`
  — falling through to `return p_vals` at 4474. **A new grid modifier that forgets to edit this chain
  silently does nothing, with no error.** The same op-string set is re-enumerated for the native-bail
  decision at 3634/3639/3667. Fix: `Pasture3DNode.apply_field(vals, ctx)` (default identity) and
  `Pasture3DNode.forces_gdscript(host)`; the loop calls the modifier.
- `_commit_modifier_caches` (4172) branches on `m is Pasture3DNodeErosion` / `m is Pasture3DNodeGraph`
  to route a deferred result into one of two separately-named queues — although the "pending" protocol
  itself is already generic (4753). A third deferring modifier matches neither branch and is dropped
  silently. Note 4204 in the *same loop* already uses the generic `if m.has_method("set_stale")`, so
  two idioms coexist five lines apart. Fix: one `_pending` queue, entries built by
  `m.make_pending(out, extent)` and stepped by `m.step_pending(entry)`.
- The `blk` / `step` parallel dicts of §3.6 are the third. One dict, one projection.
- **Fourth, added by the landed rebake-loop fix.** `_commit_modifier_caches` now gates the seed-surface
  handoff on `m != null and "material" in m and m.material != null and m.material.has_method("set_seed_surface")`
  — a four-deep inline capability probe in a generic loop, in the same function as the two branches
  above. Fold it into the protocol: `m.wants_seed_surface()` / `m.take_seed_surface(out)`, default
  false/no-op.

### 6.5 `_append_slot_inline_widget` restates every `@export_range`

[graph_editor.gd:878-1420](project/addons/pasture_3d/src/graph_editor.gd:878) is 542 lines of 91
near-identical SpinBox blocks hardcoding min/max/step that the nodes already declare. They have
**drifted, and one loses data**: `warp.frequency` is `@export_range(0.0001, 0.5, 0.0005, "or_greater")`
but the widget caps at 0.1, and `allow_greater` appears **nowhere** in `graph_editor.gd` — so a graph
authored at frequency 0.3 displays as 0.1 and is **written back as 0.1** on any interaction. 61 of the
105 node files declare at least one `or_greater` range, so the exposure is broad. Also verified wrong:
`noise_swiss.ridge_offset` (node 0.5–2.0, editor 0.1–5.0), `noise_swiss.gain` (node 0.1–1.0, editor
0.01–2.0), `strata.band_height` min and step, `strata.hardness` step, `strata.dip` step.

**Fix.** One `_spin_from_hint(row, node, prop)` reading `PROPERTY_HINT_RANGE`'s `hint_string` from
`get_property_list()`, driven by a small `{op: {port: property}}` table. Two of the function's five
parameters (`p_index`, `p_port_name`) are never read and go with it.

### 6.6 Dev/production node pairs have drifted

The 32 `[Dev/GD]` pairs duplicate ~90 lines of port metadata and parameter marshalling each. The
spec's separation covers the **execution**, not the port schema or the params dict — and 7 pairs have
drifted on defaults: `[Dev/GD] Erosion` defaults `iterations 15` / `erosion_rate 0.05` against
production's `30` / `0.08`; `[Dev/GD] Warp` defaults to `FRACTAL` / `25.0` / `50.0` against
`SIMPLEX` / `20.0` / `15.0`; `[Dev/GD] Spectral Equalizer` `micro_gain 1.0` against `1.5`. Since the
oracle exists to check the kernel, **a user who drops the dev twin beside the production node to
compare gets a different terrain and reads it as a kernel bug.** Share a per-op base holding the
exports and the params dict; the dev subclass overrides only `op()`, `display_name()`, `category()`
and the eval body.

---

## P7 — Dead code, config, hygiene and cost

Do these opportunistically alongside whichever phase touches the file. None changes behaviour except
§7.2 and §7.3.

### 7.1 Delete (pre-stack code is deleted, not shimmed)

| What | Where | Evidence |
|---|---|---|
| `raster_chamfer`, `raster_chamfer_payload`, `raster_chamfer_payload3`, `raster_polyline_field` | [brush_raster.cpp:118](src/pasture_3d_brush_raster.cpp:118), 310, 346, 383 | ~155 lines, anonymous namespace, zero external callers; `raster_chamfer_payload` is called only from the dead `raster_polyline_field` at 416. They are the octagonal-facet approximation `raster_sdf`'s own header says was replaced. |
| `_chamfer` | [terrain_brush.gd:5220](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:5220) | the GDScript twin, dead for the same reason |
| `_paint_color` | terrain_brush.gd:2332 | the only reference to `set_color_on_layer` anywhere — the colour-paint path is entirely unreachable |
| `_cross_lut` | terrain_brush.gd:3569 | note `_ridge_cross_lut` at 3588 **is** live (called from `pasture3d_ridge.gd:187`) — they look like a pair and only one is |
| `get_node_connections` | terrain_graph.gd:374 | no caller |
| `_graph_has_sink` | graph_editor.gd:1437 | no caller |
| `_dirty` | terrain_brush.gd:140/836/855/864 | the `if not _dirty: return` guard at 855 is unreachable — `_arm_refresh_timer` sets `_dirty = true` at 836 *before* creating the timer, and the only clear is at 864, so a firing timer always implies `_dirty == true`. The real queued state is `_full_dirty` / `_dirty_splines` / `_moved_node`, which 865-871 snapshot and clear. |
| `_layers_api_available` + its `elif` at 2118 | terrain_brush.gd:2101 | all four probed methods are unconditionally bound in this repo's own C++ (`pasture_3d_data.cpp` 2931/2933/2950/2951/2952), so it can only be false when `terrain.data` is null — which `is_configured()` already says |

Verified dead by `grep -rn` across `project/`, `src/`, `doc/`, `tools/` **including `project/bench/`**,
and by checking for dynamic `call("...")` dispatch.

### 7.2 Config defaults and registration

- **`gpu_raster_threshold`'s comment contradicts its value by 16×.**
  [pasture_3d_data.cpp:293](src/pasture_3d_data.cpp:293) says "Default ~256x256 cells" and sets
  **1048576** (1024²). Every stamp between 256² and 1024² silently takes the CPU path, and the perf
  spec's crossover claim is not what ships. Decide which is intended and make them agree.
- **`graph_gpu_threshold` is read but never registered.**
  [pasture_3d_graph_gpu.cpp:2082](src/pasture_3d_graph_gpu.cpp:2082) reads
  `pasture_3d/performance/graph_gpu_threshold` with a default, but no `set_setting` /
  `add_property_info` exists anywhere. The header documents it as user-tunable and
  `GraphGpuBenchGate.gd:53` tells the operator to set it there — but **the key never appears in the
  Project Settings UI**, so the gate's stated remedy cannot be carried out. Register it beside its
  sibling.
- **Expand/Shrink has no upper clamp.** [pasture_3d_morphology.cpp:205](src/pasture_3d_morphology.cpp:205)
  converts a metres radius to cells with no bound against the grid; `radius` is
  `@export_range(0.0, 500.0, 0.5, "or_greater")` and its setter only does `maxf(v, 0.0)`. Type 5000 on
  a 1 m/cell grid → `wz = 5000` → 10001 full-grid line passes × up to 64 iterations, each allocating a
  grid-sized buffer. **The editor hangs with no warning.** Clamp `wx`/`wz` to `p_gw`/`p_gh`, past
  which the kernel cannot change the answer anyway.
- **`Pasture3DReliefDLA._mark_stale()`'s docstring is now false.** The landed Phase 1 fix removed both
  the `emit_changed.call_deferred()` *and* the `if _stale: return` early-out, leaving the body as a
  bare `_stale = true`. The comment above it still explains that early-out ("the flag stays true for
  the rest of the drag, so the edge fires once") and still claims it "Mirrors
  Pasture3DNodeErosion.set_stale" — which now keeps its early-out and no longer emits. Either restore
  the early-out for symmetry with the three modifiers, or rewrite the comment; do not leave a comment
  describing code that was deleted.

### 7.3 Duplicated primitives that have already diverged

- **`smoothstep` × 8.** Six byte-identical anonymous-namespace copies (`math_ops.cpp:14`,
  `crater.cpp:14`, `curvature.cpp:16`, `furrows.cpp:15`, `geological_primitive.cpp:14`,
  `scree.cpp:17`) return `p_from` when `|from - to| <= 1e-7` — a threshold in metres handed back as a
  0..1 weight; `relief_smoothstep` (`relief_ops.cpp:40`) returns `x < from ? 0 : 1`, which is correct;
  and the shared `Pasture3DUtil` version (`pasture_3d_util.h:567`) **has no guard and divides by
  zero**. Two more sites open-code `t*t*(3-2*t)` inline. Consolidate on the header version, with the
  correct degenerate case.
- **`nan_blur` × 4.** `brush_raster.cpp:59` (6 call sites, **serial**), `graph_ops.cpp:163`
  (**threaded** via `parallel_for_rows`), `graph_ops.gd:21`, `terrain_brush.gd:3533`. The intended
  native+oracle duality is two, not four — and a threading fix already landed in only one copy, on the
  *colder* path. The C++/GDScript pair also disagree on `isnan` vs `is_finite`, the same mismatch as
  §2.4. `pasture3d_graph_ops.gd:21`'s own docstring says "Consolidate to a single caller when that
  fold lands."

### 7.4 Gate hygiene — a gate that cannot fail is not a gate

`GraphWorkerThreadGate.gd` has **no failure counter**, calls `get_tree().quit(0)` unconditionally, and
its three checks are `assert()`s — compiled out of release builds. `state["done"] == 1` after
`wait_for_task_completion` is trivially true. Its graph is only `Noise → Output`, so the regression it
is named for — a solver touching main-thread-only state from a worker, i.e. **§3.1 of this document** —
is never executed and cannot fail it. Rewrite with a failure counter, a non-zero exit, and a graph
containing an actual solver node.

Audit the neighbours for the same shape while there. Known: `GraphNodeEditorUIGate.gd:67` skips every
node with `input_count() > 0`, so only zero-input generators are evaluated despite a docstring
claiming "ALL registered graph nodes".

### 7.5 Wasted work (no behaviour change; lowest priority)

Reason statically — **do not benchmark without asking**, the machine runs another engine.

| Waste | Where | Cheaper |
|---|---|---|
| Four whole-grid field derivations built, then discarded because the native branch never passes them; `_base_below_grid` called twice with identical args | [mound.gd:244](project/addons/pasture_3d/connectors/pasture3d_mound.gd:244), 281; same shape in `plow.gd:167-173` | move them below the `_native_raster(...)` test; hoist the one `_base_below_grid` |
| `PackedInt32Array`/`PackedFloat32Array` `operator[]` — an out-of-line call through a GDExtension pointer — ~25× per op-eval inside the per-cell stack loop | [relief_ops.cpp:751](src/pasture_3d_relief_ops.cpp:751) | hoist `.ptr()` once, as `graph_eval_grid_core` already does at `graph_ops.cpp:329-348` |
| `native_supported()` + `compile_graph_program()` re-run **per graph modifier per spline** (a 5-spline brush pays 5 full compiles), each doing O(E·V) `Array.has()` scans and allocating two lambdas per node | terrain_graph.gd:523/1784/1019; called from terrain_brush.gd:4061 and 3614 | `_program_cache` / `_native_ok_cache` keyed `[root, _revision]` beside the existing `_order_cache`; make `SUPPORTED` a `const Dictionary` |
| `_modifier_signature()` (spline-invariant) recomputed per spline; the spline footprint AABB rebuilt 3× per spline per bake | terrain_brush.gd:1601, 1596, 1607 | hoist the signature above the loop; cache the AABB per instance id for the bake |
| `output_index()` (O(V) with a virtual `op()` per node) called **inside** a per-node loop on every graph `changed` — 1,600 dispatches per slider tick on a 40-node graph | [graph_editor.gd:159](project/addons/pasture_3d/src/graph_editor.gd:159) | hoist it; collapse the double `has_node`/`get_node` to one `get_node_or_null` |
| `mod_graph.gd`'s `_cache` has **no eviction at all** — a drag mints a new key per tick, each retaining a ~1 MB grid at 512² forever | mod_graph.gd:163/204 | byte budget + LRU, mirroring `_evict_cache_if_needed` |
| `_tools_on_owner(owner)` + `_overlaps_box` re-run 20 lines after the loop that already walked them | terrain_brush.gd:1477, 1501 | accumulate the tools that actually painted into a local |
| `compile_graph_program_multi` duplicates ~95 of `compile_graph_program`'s 207 lines; the 16 params arrays are declared and packed in **three** places | terrain_graph.gd:933, 1043, 1564 | `compile_graph_program(root)` → `compile_graph_program_multi([root])`; the 16 arrays become one `Array[PackedFloat32Array]`, which the native side already treats as `float P[16]` |
| `materialize` is read into a local at [terrain_graph.gd:542](project/addons/pasture_3d/graph/pasture3d_terrain_graph.gd:542) and **never used** — `{}` is passed at 558, so the documented cell-node fold does not happen and every node materialises a grid | terrain_graph.gd:542/558 | either wire it up or delete the fold machinery (`_cell_value`, `_cell_value_fast`, `_cell_input` are unreachable in practice, and `_append_input_signature`'s recursion at 778 is dead). **Note this makes §4.1 reachable sooner** by allocating N grids where 1 was intended. `GraphFoldGate` passes because both it and `_eval_unfolded` now materialise everything — another §7.4 gate. |

---

## 8. Suggested landing order

```
P1 (GPU parity)      ──┐
P2 (native output)   ──┼── independent; parallelisable across people
P3 (bake driver)     ──┤
P4 (cache keys)      ──┘
P5 (editor lifetime) ──── independent, any time
P6 (structural)      ──── LAST; rewrites what P1/P2/P4 touched
P7                   ──── opportunistic, alongside whichever file is open
```

Two down-payments on P6 are deliberately pulled forward because they are what make the earlier fix
stick rather than recur: the **grid-port index emitted from the node's port list** (§2.1 → §6.1) and
the **base-class `clear_cache` hook** (§4.1 → §6.3). Take both.

If only one phase can be done: **P1**, and within it §1.1. It is the only defect here that silently
destroys a terrain feature outright, and it is a handful of lines.
