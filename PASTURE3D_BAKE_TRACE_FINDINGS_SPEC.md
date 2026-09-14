# Pasture3D Bake Trace Findings — Junction Rebake Loop & Trace Coverage Specification

**Document Version:** 1.0
**Target Engine:** Godot 4.7+ / GDExtension (C++ / GDScript)
**Status:** SPECIFICATION READY FOR REVIEW
**Evidence:** two `Pasture3DBakeTrace` sessions on `demo_road_network.tscn`, 2026-09-13 (16:45 and 17:16)
**Builds on:** commits `22d84e77` (trace), `71304580` (digest diff marks), `af276496` (sibling drop, single arm)

---

## 1. Scope

Every finding here is read from a recorded trace, not inferred from code. Where the trace does not settle a
cause, the phase says so and instruments before it fixes.

| ID | Finding | Status |
|----|---------|--------|
| F1 | Junction digest re-arms on `-0.000` ↔ `0.000` | **Fix — Phase 1** |
| F2 | Millimetre junction drift re-arms a full layer bake | **Decision + fix — Phase 2** |
| F3 | A resolve can read ground from a bake still in flight | **Instrument — Phase 3** |
| F4 | Bakes with no recorded cause | **Instrument — Phase 4** |
| — | Point move armed twice | Fixed, `af276496`; confirmed by trace 2 |
| — | Every re-armed layer-mate repainted the whole layer again | Fixed, `af276496`; confirmed by trace 2 |
| — | `nan` pin in digests | Not a bug — see §7 |
| — | Frozen mountain graphs rebake on road edits | Not reproduced; out of scope — see §8 |

---

## 2. F1 — Signed zero keeps the junction loop alive

### 2.1 Evidence

`schedule_junction_rebake()` compares `junction_digest()` as a **string**. Each value is formatted `%.3f`, so
a quantity hovering at zero prints as `0.000` on one resolve and `-0.000` on the next. The digest changes, so
the road re-arms a full layer bake, even though no quantity moved.

Trace 2, every changed line in the pass shown:

```
25904.7  ### Road3 junction digest changed:
 - Road+Road3@156,-2|324.391|nan|10.707|0.000|0.000,0.000,0.000,0.000|-0.003,-0.003,0.000,0.000
 + Road+Road3@156,-2|324.391|nan|10.707|0.000|0.000,0.000,0.000,-0.000|-0.003,-0.003,0.000,0.000
26105.9  BAKE  Road3  path=full
26669.0  DONE  Road3  563.1 ms  (7 tool(s) repainted)
```

```
130703.2 ### Road2 junction digest changed:
 - Road1+Road2@-73,-153|151.478|nan|18.509|-0.000|-0.000,0.000,-0.000,0.000|...
 + Road1+Road2@-73,-153|151.478|nan|18.509|-0.000|-0.000,0.000,-0.000,-0.000|...
130903.5 BAKE  Road2  path=full
131316.9 DONE  Road2  413.4 ms  (7 tool(s) repainted)
```

Both passes changed nothing but a sign: **976 ms of full-layer baking in one session**. In the passes that did
carry real changes, most other lines also differ only by sign.

### 2.2 Change

In `pasture3d_road_brush.gd`, `junction_digest()` (line ~2438), route every number through one formatter:

```gdscript
## `%.3f` of a value in (-0.0005, 0) prints "-0.000". The digest is compared as text, so that sign alone
## re-armed a full layer bake (trace 2026-09-13: 976 ms across two passes that moved nothing).
static func _digest_num(p_v: float) -> String:
	var s := "%.3f" % p_v
	return "0.000" if s == "-0.000" else s
```

It must apply to **every** numeric field: arc length, pin, trim-back, elevation, and each element of the
cut-face z and bank lists, in both the END_TO_END branch and the crossing branch. A field missed is the bug
left in place (see [[component-gates-miss-wiring]]). `nan` must still print as `nan`, which it already does.

### 2.3 Gate — `JunctionDigestGate` [A]

- **Measure:** two digests of the same fixture junction, one with a field at `-0.0001` and one at `+0.0001`,
  must be **equal** strings. Cover a scalar field AND a list element, so a formatter wired to scalars only
  fails.
- **Control:** the same field at `0.0000` and `0.0020` must produce **different** strings, so a digest that
  ignores the field entirely cannot pass.
- **Control:** a `NAN` pin still prints `nan`, and differs from `0.000`.

---

## 3. F2 — Millimetre drift re-arms a full layer bake

### 3.1 Evidence

After a graph modifier was added to Road2, the junction heights drifted by millimetres and re-armed the layer:

```
46602.5  ### Road1 junction digest changed:
 - Road+Road1@96,-1|509.130|nan|10.727|0.763|-0.013,1.935,-0.000,-0.000|...
 + Road+Road1@96,-1|509.130|nan|10.727|0.763|-0.013,1.935,0.004,0.015|...
46780.6  BAKE  Road2  path=full
47138.4  DONE  Road2  357.8 ms  (7 tool(s) repainted)
```

That is 4 mm and 15 mm, and it cost a 358 ms layer bake. The change is real, so F1 does not remove it.

### 3.2 Decision required

Whether a sub-centimetre junction change justifies a full layer rebake is a **tolerance decision, not a bug**.

**Recommendation: compare numerically against a tolerance, not by rounding.** Rounding to 0.01 still flips
when a value sits on a rounding boundary (0.00499 ↔ 0.00501). A tolerance has no boundary to sit on.

- Store the last-baked digest **values** (per junction id: an array of floats) beside the string.
- Re-arm when the set of junction ids differs, a list changes length, a NaN-ness changes, or any field
  differs by more than its tolerance.
- Proposed tolerances, **to be confirmed by the user**:
  - heights and elevations (elevation, pin, cut-face z): **0.01 m**
  - arc lengths and trim-back: **0.01 m**
  - banks: **0.001**

A real drag moves arc lengths by metres (trace 2: `795.800 → 797.082`), so none of these hide an edit.

**Risk to check:** repeated sub-tolerance drift can accumulate. Compare against the values recorded at the
**last bake**, never against the previous resolve, so drift accumulates until it crosses the tolerance and
then triggers exactly one bake.

If the tolerance is adopted, F1's string formatter stays in place for the trace diff output, but no longer
decides re-arming.

### 3.3 Gate — `JunctionDigestGate` [B]

- **Measure:** a 4 mm z change does **not** request a rebake.
- **Control:** a 20 mm z change **does**.
- **Accumulation:** five successive 3 mm changes, recorded only when a rebake fires, request **exactly one**
  rebake: at the fourth step, when the drift reaches 12 mm. This fails if the comparison is against the
  previous resolve instead of the last bake.
- **Structural:** a junction appearing or disappearing requests a rebake regardless of magnitude.

---

## 4. F3 — A resolve can read ground from a bake still in flight

### 4.1 Evidence (insufficient to fix)

Trace 2, first junction loop after a Road2 drag. `Road+Road1@96,-1` changed and then **changed back**:

```
24078.6  Road1:  - ...|-0.007|-0.000,0.224,-0.000,-0.000|...   + ...|0.000|0.000,-0.000,-0.000,-0.000|...
25065.3  Road1:  - ...|0.000|0.000,-0.000,-0.000,-0.000|...    + ...|-0.007|-0.000,0.224,0.000,0.000|...
```

A 0.224 m cut-face height went to zero for one resolve and returned. It happened once and settled. It is not
a sustained cycle, but it cost one full pass: the Road3 bake at 25313, 561 ms.

The resolve at 24078 ran 30 ms after a Road2 **rect** bake (DONE at 24048) that had re-armed Road2 for a full
bake via `_rebake_if_corridor_outgrew` (armed at 24501, inside the following Road4 bake). The hypothesis
is that the resolve sampled ground graded to the too-narrow corridor. **The trace does not show what the
resolve read**, so this phase does not fix anything.

### 4.2 Change — instrument only

- `pasture3d_road_network.gd`, `resolve_junctions()`: add `Pasture3DBakeTrace.mark()` at entry, recording
  which brushes have a **pending** full refresh (`_full_dirty` or a live `_timer`) and whether any brush on the
  network has `_erosion_running` or a deferred run in flight.
- In the digest-changed mark, include per changed junction the **ground height sampled at its centre**, so a
  revert can be tied to a ground change.

### 4.3 Acceptance

A trace of the same drag shows, for any junction whose value reverts, whether a full refresh was pending when
the reverting resolve ran. Then **one** of the following gets specified in a later revision:

- defer `resolve_junctions` while any network road has a pending full refresh, or
- close the question as benign (a single settling pass).

---

## 5. F4 — Bakes with no recorded cause

### 5.1 Evidence

Trace 2 contains `BAKE` events with no `ARM` before them since the previous `DONE`:

| Time | Brush | Path | Note |
|------|-------|------|------|
| 36397 + 36475 | Plow | rect ×2 | one drag, two bakes 50 ms apart |
| 53315, 56238, 66189 | Road2 | rect | no arm |
| 61274 → 61693, 63238 → 63715 | Road2 | full | `DEFERRED` then `HIT`: the deferred driver's two passes, **expected** |
| 90144 + 90185 | Mound | full ×2 | one arm (`ensure_graph_modifier`), two bakes |

These enter through paths that do not use the three schedulers: `refresh()`, `force_bake_modifiers()`, undo
restoring via `_restore_owner`, and the deferred driver's second pass. The trace cannot yet say which, so the
Plow and Mound double bakes cannot be classified as redundant or as driver passes.

### 5.2 Change

- `Pasture3DBakeTrace.bake_begin(p_brush, p_path)` records `_stack()` when `capture_stacks` is on, the same
  way `arm()` does. `report()` prints it under `BAKE` as `entered via`.
- Stack capture stays opt-in through `capture_stacks`. `bake_begin` is far rarer than `arm`, so its cost is
  immaterial.
- The deferred driver marks pass 1 and pass 2 (`_bake_deferred`), so driver passes read as such rather than as
  unexplained repeats.

### 5.3 Gate — `BakeTraceGate` [H]

- **Measure:** a real `_refresh_owner` with `capture_stacks = true` records a `bake_begin` whose stack
  contains this gate's own calling frame (`BakeTraceGate.gd`).
- **Control:** with `capture_stacks = false`, the stack is empty.
- The gate MUST NOT assert on a stack it built itself; the frame it looks for is the one that called
  `_refresh_owner` (see [[a-gate-that-calls-the-node-measures-nothing]]). If `get_stack()` is empty headless,
  [H] reports itself as not covered, as [F] does, rather than passing on an empty array.

### 5.4 Acceptance

A trace of the Plow drag and of Add Graph on the Mound names the entry point of every `BAKE`. Any double bake
not explained by the deferred driver becomes a finding in a later revision.

---

## 6. Phase order

| Phase | Finding | Depends on | Changes behaviour |
|-------|---------|-----------|-------------------|
| 1 | F1 signed zero | — | yes |
| 2 | F2 tolerance | user confirms tolerances; supersedes F1's re-arm role | yes |
| 3 | F3 instrument | — | no (trace only) |
| 4 | F4 instrument | — | no (trace only) |

Phases 3 and 4 are independent of 1 and 2 and can land first. Do Phase 1 even if Phase 2 is approved: it is
one function, and it keeps the trace diffs free of sign noise.

### 6.1 End-to-end acceptance

Repeat trace 2's scenario after Phases 1–2: in `demo_road_network.tscn`, drag one Road2 point that changes a
junction, then release.

- **Before (trace 2, 24078 → 26669 ms):** 3 full layer bakes, 1799 ms.
- **Target:** no digest-changed mark whose diff differs only by sign; no rebake for a diff where every field is
  within tolerance.
- Report the measured count and total ms against that baseline. Do not claim a target number beforehand.

Every phase ends with `git status`. Gates build their terrain in memory, and must not touch
`project/demo/data` ([[gate-data-directory-is-an-editor-risk]]).

---

## 7. Closed: `nan` pin is by design

`Pasture3DRoadJunction.pin_for()` (`pasture3d_road_junction.gd:340`) returns `NAN` for the major road and for
a disabled junction. The major road sets the junction elevation rather than being pinned to it. `nan` formats
identically every time, so it never re-armed anything in either trace. No change.

## 8. Out of scope: frozen mountain graphs rebaking on road edits

The original report (mountains with frozen graphs re-solving when a road is edited) was not reproduced. Both
traces ran in a scene without mountains. Trace 2's `GRAPH` events are all Road2's own graph, and show the
cache behaving as designed: `DEFERRED` → `HIT` driver pairs, `STALE` served while frozen, `MISS` only once
the modifier was set to live.

Next step: run a trace in the mountain scene while editing a road. If a mountain `ARM` or `GRAPH` appears,
its `woken by` stack is the cause, and it gets its own specification.
