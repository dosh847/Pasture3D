# Pasture3D Road — Staleness Remediation & Cost Reduction

**Document:** `PASTURE3D_ROAD_STALENESS_AND_COST_SPEC.md`
**Status:** **Phase 1 complete — S1, S2, S3 and S4 BUILT 2026-09-03** (`RoadStaleGate` [SA]–[SH] pass,
controls verified; 36 assertions; 14 road gates and 5 graph gates green).
**S6–S12 (cost) PROPOSED, not started.** Check the symbol and the branch before planning from this header; it
will go stale before the work does.
**Target:** `Pasture3DRoadBrush` and its integration with the modifier stack, the road network resolve
loop, and the terrain node graph.
**References:** `PASTURE3D_ROAD_SYSTEM_PROPOSAL.md` §5.3, §6, §8, §10;
`PASTURE3D_ROAD_BRUSH_PERF_SPEC.md` (§4 invariant table is corrected here — see §9);
`PASTURE3D_ROAD_PERF_REGRESSION_SPEC.md` (R4, R5 and the `Input.` prohibition are load-bearing here).
**Phases:** **S1–S4** correctness, then **S6–S12** cost. S1 gates everything else.

---

## 1. Objective

Twelve findings came out of a review of the road brush and its integration. This document orders them
into landable phases, correctness first, then cost by impact. It is not a list of twelve independent
patches: **four of the five correctness defects are one defect seen from four places**, and saying so is
the whole value of the ordering.

---

## 2. The shared root cause — three caches, all keyed on less than they hold

The road system has three memoisations between the authored road and what the user sees. Each one is
keyed on a subset of what its value depends on, and the missing part is the same in all three: **the
resolve chain** (§5.3) and everything downstream of it.

| Cache | Key | What the key cannot see |
|---|---|---|
| `_stamp_cache` (`pasture3d_terrain_brush.gd:1644`) | `_compute_stamp_key` = global transform, `curve.get_baked_points()`, `_brush_param_signature()`, `_modifier_signature()` | The resolved road type, lane count, `follow_terrain`, every `Pasture3DRoadSegment`, the junction pins, and the corridor width the bake committed to |
| `Pasture3DGraphNodeRoadSource.path` (`pasture3d_road_network.gd:760`) | `points`, `half_widths`, `heights` | `crown`, `cut_batter`, `fill_batter`, `sample_verges`, `sample_shoulders`, `sample_suppress`, `sample_skip` |
| `Pasture3DRoadChunkHost._last_digest` (`pasture3d_road_chunk_host.gd:157`) | Names its inputs one at a time — **this one is right**, and is the model the other two should follow | — |

This is the memoisation trap the project has hit before: a consumer copies its inputs' bytes, an input
changes without saying so, and the stale answer is indistinguishable from a correct one. It is also the
wiring shape the P2 lessons named — a value defined in three places is fixed in none. The chunk host
already solved it, in a comment that explains exactly why an instance id is not a key
(`pasture3d_road_chunk_host.gd:138-156`). **S1 generalises that solution; it does not invent one.**

### 2.1 Why this was not caught

`_refresh_owner` runs `_apply_surface_snap()` before `_paint_into` (`pasture3d_terrain_brush.gd:954-957`),
and road brushes default `snap_to_surface = true` (`pasture3d_road_brush.gd:289`). When the previous bake
moved the ground under a control point, snapping moves the point's Y, `curve.get_baked_points()` changes,
and the stamp key changes *by accident* — so the re-bake lands. When the ground did not move, it does not.

**The bug is therefore intermittent and terrain-dependent**, which is why it reads as "roads sometimes
don't take" rather than as a cache defect. It also means a gate that asserts only the terrain outcome can
pass by accident. Every S1–S3 criterion below asserts the **cache decision** — did `_paint_spline`
actually run — not just the height field.

---

## 3. Phase 1 — Correctness

### S1 — The stamp key is blind to road content — **BUILT**

**Where:** `pasture3d_road_brush.gd` (no `_brush_param_signature` override);
`pasture3d_terrain_brush.gd:1614-1628`.

**Symptom.** Three separate features silently do nothing:

1. **Junction pins never reach the terrain.** `schedule_junction_rebake()` (`:1232`) advances
   `last_junction_digest` and calls `_schedule_refresh()`. That sets `_full_dirty` but does not populate
   `_dirty_splines` and does not clear `_stamp_cache` (`:797-801`), so `_paint_into` (`:1603`) recomputes
   an identical key, hits the cache, and replays the block solved **without** pins. `_paint_spline` never
   runs, so the alignment is never re-solved either. Because `last_junction_digest` was already advanced,
   the next resolve does not ask again. The minor road stays at the height it wanted before it was asked
   to meet the major road.
2. **The corridor never widens.** The `_widening` block (`:419` and `:726`) exists because the batter's
   reach is only known after the alignment is solved, so the first bake of a deep cutting is necessarily
   too narrow. It calls `_schedule_refresh()` — into the same cache hit. The wider footprint
   `_padding()` would now ask for is never rasterised, and the sheer wall the block was written to
   remove stays.
3. **Every road-content edit is discarded.** See S2.

**Root cause.** `_compute_stamp_key` hashes geometry and modifier params. A road's baked surface also
depends on the resolve chain, the segments, the junction pins and the corridor width — none of which the
key can see.

**Fix.** Override the established extension point, exactly as Ridge, Trough, Mound, Plow and Splat
already do (`pasture3d_ridge.gd:268`):

```gdscript
func _brush_param_signature() -> Array:
    return [super._brush_param_signature(), road_content_signature()]


## As built. Written as a list of named inputs rather than a generic property hash, for the reason the
## chunk host already gives at :138 — a generic hash churns on inputs the height bake never reads and
## forces a full re-rasterise on edits that move no vertex.
func road_content_signature() -> Array:
    var t := resolved_road_type()
    var segs: Array = []
    for seg: Pasture3DRoadSegment in segments:
        segs.append(seg.signature() if seg != null else null)
    return [
        closed,
        resolved_lane_count(), resolved_follow_terrain(), resolved_one_way(),
        String(resolved_surface_id()),
        t.grading_signature() if t != null else null,
        # The brush's own level of the chain. The group's and the network's reach us through the
        # resolved_* calls above, which is why they are not signed separately.
        road_defaults.signature() if road_defaults != null else null,
        segs,
        junction_digest(),
        snappedf(_padding(), PAD_QUANTUM),
    ]
```

`RoadStaleGate.TERM_NAMES` mirrors that order and every criterion addresses terms by name, so inserting
a term in the middle fails the gate as a wrong *name* rather than silently re-pointing a criterion at its
neighbour.

Two of those terms need their own justification.

**`snappedf(_padding(), PAD_QUANTUM)`** is what replaces the `_widening` machinery outright. Padding is a
function of `corridor_half_width()`, which reads `_deepest_structure()` from the alignment the *last*
bake solved — so it changes exactly once after the first bake of a deep cutting, and the key change is
what makes the second bake a cache miss. It converges in one extra pass because the second bake solves an
identical alignment (the alignment is sampled along the plan and does not depend on grid width), so the
third key equals the second. Quantise it — `PAD_QUANTUM = 0.5`, the band the old
`_last_corridor_half + 0.5` test was already expressing — because a raw float in a hash key means every
bake mints a new key and the cache never hits again.

**`junction_digest()`** is already computed on this path; folding it in is what makes S1 fix symptom 1
without any change to `schedule_junction_rebake`.

Then **delete** `_widening`, `_last_corridor_half`, and both `(func(): _widening = false).call_deferred()`
lambdas, and replace both re-bake triggers with a comparison against the padding *this* bake used:

```gdscript
var used_pad := _padding()   # captured BEFORE _spline_footprint_aabb committed the grid
...
if snappedf(_padding(), PAD_QUANTUM) > snappedf(used_pad, PAD_QUANTUM):
    _schedule_refresh()      # the key now differs, so this is a real re-bake, not a replay
```

That deletes three problems at once. The old guard was inert — `_widening` is cleared by `call_deferred`
at the end of the frame, while `_schedule_refresh` arms a `REFRESH_DELAY = 0.1 s` timer, so the flag was
always false by the time the bake it guarded ran; termination rested entirely on `_last_corridor_half`.
And `_last_corridor_half` is an unsaved `var` initialised to `0.0`, while `corridor_half_width()` returns
at least `allowance / batter` (≥ 12 / 0.6 = 20 m with default batters) — so on the **first bake after
every scene load, undo and plugin reload**, every road brush fired a redundant `_schedule_refresh()`, and
each of those ran `_refresh_owner` over the whole shared layer. N road brushes meant N redundant
full-layer bakes before anything had changed. Comparing against the padding the current bake used has no
persistent state, no flag, and no first-bake special case.

**What must not break — two claims in the first draft of this section were wrong, and building it
found them.**

*The alignment terms belong in `grading_signature()` after all.* The draft said to leave out `max_grade`
and `design_speed` because "`alignment_digest` already covers them". It does — and `alignment_digest` is
not part of the stamp key. It guards the *stored profile* in `restorable_alignment`, which is a different
cache answering a different question. Leaving them out would have left a `max_grade` edit re-solving the
alignment and then replaying the old block over it. **A cross-check that lives somewhere else is not a
key.** `grading_signature()` as built carries `lane_width`, `lane_count`, `shoulder_width`, `crown`,
`verge_width`, `cut_batter`, `fill_batter`, `max_grade`, `max_superelevation`, `design_speed` — and not
`type_name`, `priority`, `divider_type`, the `prop_*` fields, `surface_id`, `surface_layer_id` or
`surface_material`, none of which move a terrain vertex.

*The chunk host must NOT call `road_content_signature()`.* The draft said to collapse the two lists so
they cannot drift. That would have made each rebuild on the other's edits — the exact churn the chunk
host's own comment at `:138` exists to prevent. The mesher reads `surface_material` and `depth_lift`,
which move no terrain vertex; the height bake reads the batters and `max_grade`, which move no ribbon
vertex. They stay two lists and share **one reading of the road type's cross-section**: the brush through
`grading_signature()`, the host through `half_width(resolved_lane_count())`. `[SG]` gates exactly that
asymmetry — a `lane_width` edit must move both, a `cut_batter` edit must move only the brush's.

*The segment signature lives on the base.* `Pasture3DRoadSegment` **extends** `Pasture3DRoadOverrides`
rather than holding one, so `signature()` is defined on the override resource (the six inheritable
fields, sentinels included — a field returning to INHERIT is as much a change as setting it was) and the
segment overrides it to add the range and the structure flags. `road_type` contributes its
`grading_signature()` rather than its instance id, so editing a shared type invalidates every brush using
it — the failure mode R4 had to rescue the chunk host's digest from.

**Gate:** `[SA]`, `[SB]`, `[SC]`, `[SF]`, `[SG]` — `RoadStaleGate`, all passing.

**One thing the build changed about the code, found by a control failing.** `_rebake_if_corridor_outgrew`
returns `bool` rather than `void`. `_schedule_refresh` early-returns unless `Engine.is_editor_hint()`, so
headless `_full_dirty` never moves and a gate watching it sees nothing whichever way the function decides
— "measured nothing" and "measured well" were indistinguishable, and `[SC]`'s first half passed vacuously
on the first run. The control caught it. The decision is now the return value; the caller ignores it and
the gate is the reader.

---

### S2 — Road, group, network and road-type edits never schedule a bake — **BUILT**

**Where:** `pasture3d_road_brush.gd:145`; `pasture3d_road_group.gd:86`; `pasture3d_road_network.gd:268`;
and the absent connection to `Pasture3DRoadType.changed`.

**Symptom.** Change `road_lane_count` from 2 to 6, pick a different `road_type`, flip
`road_follow_terrain`, tick `is_bridge` on a segment, edit the group's or the network's `road_defaults`,
or edit `lane_width` on the `Pasture3DRoadType` resource itself. Nothing happens. The terrain keeps the
old corridor until an unrelated edit forces a bake — and once S1 is in, that bake will finally be correct,
which is why S1 lands first.

**Root cause.** Three unread counters and one missing connection.

- `Pasture3DRoadBrush._on_road_changed` increments `content_key` and calls
  `update_configuration_warnings()`. It does not call `_schedule_refresh()`. Every sibling brush does the
  equivalent (`Pasture3DRidge.width` → `_schedule_refresh`).
- `Pasture3DRoadGroup._bump` and `Pasture3DRoadNetwork._bump` increment their own `content_key` and stop.
  Nothing reaches the child brushes, so a catalogue or group-defaults edit changes every road's resolved
  values and re-bakes none of them.
- `Pasture3DRoadType` emits `changed` on every property and nothing in the roads package connects to it.
  R4 in the regression spec fixed the *ribbon* by widening the chunk host's digest; the **terrain** was
  left behind, because a road-type edit still schedules no bake for the digest to be consulted by.

All three `content_key` fields are written and never read. Grep confirms it: the only readers of a symbol
by that name are `Pasture3DNodeRoad.content_key()` and `Pasture3DTerrainGraph.content_key()`, which are
unrelated methods on other classes.

**Fix.**

1. `_on_road_changed` calls `_schedule_refresh()`. `_can_auto_refresh()` already guards
   `is_inside_tree()`, so the call is a safe no-op during `_init` and scene load.
2. `Pasture3DRoadBrush` connects to the resolved `Pasture3DRoadType.changed` and to its group's and
   network's `content_changed`, disconnecting on reparent. Give the group and network a real
   `content_changed` signal and emit it from `_bump`, rather than leaving a counter nobody polls.
3. **Delete all three `content_key` fields.** `road_content_signature()` supersedes them: it is read, it
   is content-addressed rather than a change count, and a change count could never have been used as a
   cache key anyway — it detaches on undo, where the value returns but the counter does not.

**What must not break.** A network-level edit must schedule **one** bake per affected brush, not one per
brush per property touched. `[SD]` asserts `== 1` rather than `>= 1`: the brush attaches to its group AND
its network AND its road type, and if any two of those paths carried the same edit, one property change
would buy two full-layer bakes on a shared layer. `>= 1` would not notice.

**What the build added that the plan did not have.** The group, the network and the road type cannot
connect at a setter the way `road_defaults` and `segments` do — the first two are found by walking
parents and the third is **resolved through the chain**, so any of them can be replaced without a setter
on the brush firing. So there is a `_rewire_content_sources()` that re-derives all three and is called
from `_ready`, from `NOTIFICATION_ENTER_TREE` (a reparent exits and re-enters the tree, and `_ready` runs
once — the base class uses the same notification to re-join the brush group, for the same reason) and
from `_on_road_changed` itself, *before* the refresh, because the thing that changed may have been the
road type. `[SD] rewire` gates that last case: after switching types the brush must follow the new
resource and stop hearing the old one.

**A gate was asserting the bug.** `RoadModelGate` had a control reading `grp.content_key` and checking it
had moved. It passed throughout — while a group defaults edit reached no brush and re-baked no terrain.
A counter moving is not a consumer being told, and the control could not tell the two apart. It now
counts `content_changed` at a real listener.

**Gate:** `[SD]` — `RoadStaleGate`, five sources asserted separately plus a control and the re-wire.

---

### S3 — `_assign` compares three of eleven fields, so cross-section edits never reach the graph — **BUILT**

**Where:** `pasture3d_road_network.gd:756-763`.

**Symptom.** A graph wired `Road Source → Road Grade`. Set `crown_override`, `cut_batter_override`,
`fill_batter_override` or `verge_override` on the `Pasture3DNodeRoad`, or mark a segment as a bridge.
The brush's own grading step follows; the graph's does not. Two roads, differing by centimetres in the
corners, from one spline — which is the exact failure `graph_path()`'s header says the design exists to
prevent.

**Root cause.** `_assign` early-returns when `points`, `half_widths` and `heights` all match. A
cross-section edit changes none of those: `crown` and the batters are not geometry, and `sample_suppress`
/ `sample_skip` do not move the solved profile. The rebuilt `Pasture3DGraphPath` is discarded and the node
keeps the old one. Nothing else rescues it — `sample_half_widths`, `sample_shoulders`, `sample_verges`,
`sample_suppress`, `sample_skip`, `crown`, `cut_batter` and `fill_batter` are plain `@export` vars with no
setter that emits `changed` (`pasture3d_graph_path.gd:110-126`), so the node's revision never bumps and
every downstream cache stays warm on stale input.

**Fix.** Give `Pasture3DGraphPath` a `content_digest() -> int` covering **every** field a consumer reads
— the three geometry arrays, all five sample arrays, the three cross-section scalars, `closed` **and the
`alignment`** — and make `_assign` compare that. Do the same in `Pasture3DGraphSources._assign`
(`:113-119`), which today compares only `closed` and `points` and has the identical hole for a shape's
outline.

**The alignment was not in the plan and belongs in the digest.** The draft listed thirteen fields and
omitted `alignment`, on the reasoning that `heights` covers elevation. It does not: `heights` is per
*vertex*, the alignment is per *sample*, and `Pasture3DRoadGrader` grades from the alignment. A re-solved
profile with unchanged plan geometry — exactly what a `max_grade` or `smooth_radius` edit produces — would
have been discarded. `Pasture3DRoadAlignment.content_digest()` is new for this, and covers the solved
profile (`ds`, `s0`, `z`, `ground`, `curvature`, `bank`, `pinned`) but **not** the diagnostics: two
alignments with identical geometry and different `cut_volume` reports grade to the same terrain, and
including them would invalidate a downstream cache over a number nothing downstream reads. `input_digest`
is excluded for a sharper reason — a digest of a digest of the inputs is not a digest of the result.

**What must not break.** The narrowness is not an accident, it is an over-correction: `RoadGraphGate [G]`
asserts *cache preservation on an identical re-resolve*, and assigning unconditionally would bump the node
revision on every bake and re-solve every downstream erosion from scratch. So the fix is **compare
everything, cheaply** — never "assign always". The digest must be computed from the packed arrays'
existing hashing, not by iterating them in GDScript, or S3 hands back the cost S6 is about to remove.

**Gate:** `[SE]` — `RoadStaleGate`, eight cross-section fields asserted separately.

**The control is the opposite property, not a broken variant.** `[SE] identical` asserts that two paths
built from the same road still compare equal — `RoadGraphGate [G]`'s rule, restated *inside* this
criterion so a future "fix" cannot satisfy [SE] by assigning unconditionally and throwing [G] away. The
second control is `source_label`: a field no query reads must not invalidate anything downstream, or a
rename in the inspector re-solves every erosion below the node.

The fixture populates every array with non-degenerate values. Arrays left empty hash equal to each other
whichever one an edit touches, and half the cases would pass without the digest covering anything.

---

### S4 — `closed` closes nothing but the gizmo — **BUILT**

**Where:** `pasture3d_road_brush.gd:54` and `:840`.

**Symptom.** Place a road, lay out a ring, tick `closed`. The gizmo draws a last→first segment. The
grader, the mesher, the arc-length space, the junction detector and the graph path all still see an open
road with a gap at the seam.

**Root cause.** `_new_spline` sets `curve.closed` from `_is_closed()` **at creation time**
(`pasture3d_terrain_brush.gd:2943`), when `closed` is still `false`, and the setter never revisits it. And
`_plan_points()` concatenates `curve.tessellate()` with no wrap, unlike `Pasture3DRidge`, which appends
`pts[0]` explicitly for exactly this reason (`pasture3d_ridge.gd:161`). Meanwhile `brush_handles._is_closed`
reads the brush flag directly, which is why the gizmo alone obeys it.

**Fix.** In the `closed` setter, write `curve.closed` through to every child spline and call
`update_gizmos()` — the two things `Pasture3DRidge.closed` already does (`pasture3d_ridge.gd:74-79`).

**Do NOT wrap the polyline in `_plan_points()`. The first draft of this section said to, and it was
wrong.** `Curve3D.closed` already bakes the closing segment: measured on a 4-point 300 m square,
`tessellate()` goes from 4 points to 5 — the last exactly equal to the first — and `get_baked_length()`
from 300.000 m to 399.999 m. So the wrap arrives through the `tessellate()` call `_plan_points` already
makes, and appending `pts[0]` on top of it would give the road **two** closing edges with a zero-length
segment between them. Ridge wraps manually because it reads control points rather than a tessellation; a
road does not, and copying Ridge here would have doubled the seam. `[SH] no double wrap` is the criterion
that refuses it.

**`_ready` reconciles.** A scene saved with `closed == true` on the brush and `closed == false` on every
curve — which is every scene saved before this fix — needs `_apply_closed_to_splines()` on load, or the
user has to toggle the box twice to see a ring.

**`graph_path()` carries the seam as the flag, not as a vertex.** The plan already ends at its start, so
handing it to a `Pasture3DGraphPath` with `closed = true` would close it a second time — the resource
repeats `points[0]` itself. The duplicate vertex (and its half-width and height) is dropped and the flag
set instead. Told rather than implied, because `closed` is what makes `inside()` answerable, which is how
a ring road's interior becomes usable as a graph mask.

**What must not break.** Closing a road **changes its total arc length**, which moves every
`Pasture3DRoadSegment` range, every junction arc length and every `Pasture3DRoadRoute` waypoint. That is
correct — the road really did get longer — but it must be stated, and `_get_configuration_warnings`
already surfaces out-of-range segments via `s.range_warnings(total)`. `closed` is in
`road_content_signature()` (S1), so the bake follows.

**Gate:** `[SH]` — `RoadStaleGate`, not `RoadModelGate` as the draft said: `RoadModelGate` was being
edited concurrently by the bench-gate data-directory work, and a criterion is not worth a merge conflict.

Six assertions. None of them reads `_is_closed()`, because **the flag was never the broken part** — it
returned `closed` correctly throughout, which is exactly why the gizmo drew a ring over a horseshoe. They
read the curve, the plan, the plan's length, the absence of a doubled wrap, the graph path, and the
revert. The fixture is three sides of a square so the seam is a long unambiguous distance; a nearly-closed
shape would let the length criterion pass on a fixture that was already a ring.

---

### S5 — Order note

There is no S5. The fifth correctness finding — the inert `_widening` guard and the spurious first-bake
double-bake — is **fixed by S1's construction**, not alongside it, and is written up there. It is called
out separately only so the review's twelve findings map onto this document without a gap.

---

## 4. Phase 2 — Cost, highest impact first

### 4.1 Impact ranking vs. landing order

These differ, and the difference is deliberate.

| Rank | Item | Why it ranks here | Land at |
|---|---|---|---|
| 1 | **S7** — scope the network resolve | Multiplier: one road's drag pays for N roads' repaint, re-chunk and runtime rebuild | 2nd |
| 2 | **S6** — cache `_plan_points` | Largest constant factor; sits under S7, S8 and S9 | **1st** |
| 3 | **S8** — `alignment_digest` | ~25 000 String formats per road per resolve, inside S7's loop | 3rd |
| 4 | **S9** — `grading_profile` resolve hoisting | ~25 000 ancestor walks per call, on a path that always runs | 4th |
| 5 | **S10** — GDScript footprint pass | O(cells × segments) interpreted, on the §8 Road+Graph path | 5th |
| 6 | **S11** — `corridor_half_width` memo | O(alignment) per editor click per road | 6th |
| 7 | **S12** — pick path | One CPU raymarch per road per click | 7th |

**S6 lands first despite ranking second** because it has no semantic surface at all, and because it is
what makes S7 measurable: with the tessellation cached, the remaining cost of the resolve loop is the
work itself rather than the re-derivation, so a counter on `build_run()` calls means something.

### 4.2 Gates are counters, not clocks

Every criterion in `RoadCostGate` is a **call count, allocation count or work-unit count** — how many
times `_plan_points()` tessellated, how many `build_run()` calls one resolve made, how many cells the
footprint loop visited. Counts are deterministic, they fail loudly on a regression, and they do not
depend on what else the machine is running.

**No wall-clock benchmark runs without asking first.** If a measured millisecond figure is wanted to
confirm a ranking, ask before running it — this machine shares its load with another engine, and a number
taken under that load is worse than no number.

---

### S6 — `_plan_points()` is uncached and re-tessellated everywhere

**Where:** `pasture3d_road_brush.gd:840`.

**Cost.** Every call allocates a fresh `PackedVector2Array` from `path.curve.tessellate()` across all
child splines, with no memoisation. Callers: `_paint_flat_footprint`, `grade_surface`, `alignment_digest`,
`build_run`, `graph_path`, `paint_bounds`, `point_at_arc`, `tangent_at_arc`, `pick_road_screen_distance`.
`Pasture3DRoadNetwork._arms_for` alone calls `point_at_arc` and `tangent_at_arc` twice per junction end per
participant, and each of those re-runs `_plan_points()` **and** `Pasture3DRoadGrader.cumulative_length()`
from scratch.

**Fix.** Memoise the pair `(plan, cum)` behind a revision counter, invalidated from the hooks that already
exist: `_on_path_curve_changed` (`:597`), `_schedule_transform_refresh` (`:808`), `_on_child_changed`
(`:609`), and the `closed` setter (S4). Cache `cum` with the plan — it is derived from it and is recomputed
just as often. Publish `point_at_arc` / `tangent_at_arc` off the cached pair rather than rebuilding it.

**What must not break.** The invalidation must be conservative: a missed invalidation here is a road
graded along a centreline it no longer has, which is strictly worse than the cost being removed. The
revision must also cover a spline being *added or removed*, not only edited — `_on_child_changed` is the
hook, and `Pasture3DRoadChunkHost` is already exempt from it via `INTERNAL_CHILD_META`.

**Gate:** `[CA]`.

---

### S7 — Every road bake rebuilds the entire network

**Where:** `pasture3d_road_network.gd:333`.

**Cost.** Every road bake ends in `jnet.request_resolve()` (`pasture3d_road_brush.gd:494` and `:744`).
`resolve_junctions()` then, for a twenty-road network, on a single control-point drag:

- calls `build_run()` on all twenty brushes;
- runs `_resolve_lane_graphs`, whose `_arms_for` re-derives the plan four times per junction participant;
- calls `paint_roads`, which clears **and repaints all twenty** roads' control layers, through
  `clear_layer_in_area` at whole-tile granularity;
- calls `build_chunks`, a second `build_run()` per road plus `alignment_digest()` per road, then
  `build_junction_surfaces`, a third `build_run()` per junction;
- calls `build_runtime`, a fourth `build_run()` per road plus `surface_intervals()` and
  `corridor_half_width()` per road — and then assigns `runtime`, `run_ids` and `next_run_id`, all
  `@export`, **dirtying the scene on every drag**.

Nineteen roads that did not move pay in full for the one that did.

**Fix, in the order the risk rises.**

1. **Stop re-baking `runtime` on every resolve.** The baked runtime is a *deliverable*, not a live
   derivative — its own header says it exists so a game can load it without the editor. Move
   `build_runtime` off `resolve_junctions` onto an explicit "Bake Runtime" action plus the existing Bake
   All path, and leave a staleness warning behind. This alone removes a quarter of the work and stops the
   scene being dirtied by a mouse drag.
2. **Make `paint_roads` and `build_chunks` incremental.** Both already have the information: the chunk
   host has a per-road digest, and `paint_roads` clears per shared layer over the union of the roads on
   it. Restrict the union to roads whose `road_content_signature()` or junction participation changed.
   The clear must still be per *layer* over a union, not per road — the existing comment at `:981-987`
   explains why clearing per road drops a neighbour's cells at a shared tile boundary, and that reasoning
   survives.
3. **Keep the resolve itself whole.** Junction detection is a fact about pairs; scoping it to "roads near
   the edited one" is a correctness risk for a cost that S6 and S8 largely remove.

**What must not break — read `PASTURE3D_ROAD_PERF_REGRESSION_SPEC.md` R5 before touching this.** The
previous attempt at this coalescing consulted `Input.is_mouse_button_pressed` inside the bake kernels and
dropped the resolve for every newly placed road. `Pasture3DRoadBrush` now contains no `Input.` reference
at all, and `RoadJunctionGate [U]` has a criterion asserting that. **No fix in this document may
reintroduce one.** Coalescing belongs inside `request_resolve`, where it applies to every caller and does
not consult global state; the scoping proposed above is content-addressed, not input-addressed.

**Gate:** `[CB]`, `[CC]`.

---

### S8 — `alignment_digest` string-formats every tessellated plan point

**Where:** `pasture3d_road_brush.gd:986-1004`.

**Cost.** A 5 km road tessellates to roughly 25 000 points at Curve3D's default spacing. The digest does
25 000 `String` formats, a 25 000-element `join` and a hash of the resulting ~500 KB string. It is called
from `_paint_flat_footprint` (`:416`), `grade_surface` (`:715`), `restorable_alignment` (`:1019`) and —
the one that hurts — `Pasture3DRoadChunkHost.rebuild`'s digest (`:158`), which runs for **every road on
every resolve**, purely to decide that nothing changed. On a twenty-road network that is half a million
String formats per spline drag.

**Fix.** Replace the per-point formatting with an incremental numeric hash over the packed array — the
same `hash()` over `PackedVector2Array` the stamp key already relies on — combined with the scalar terms.
Keep the digest a `String` in the stored field so `input_digest` stays compatible with saved alignments;
only the derivation changes.

**What must not break.** The function's own header states the property that matters: **the digest must be
computed the same way when storing and when checking.** Both callers already go through this one
function, so the change is safe by construction — but the gate must assert a round trip, because a
staleness test that passes when it should fail is the one failure mode a guard must not have. Changing the
derivation invalidates every alignment saved by an older build; those roads correctly report "needs a
bake" rather than being restored wrong, which is the designed behaviour of `restorable_alignment` and
should be stated in the changelog rather than worked around.

**Gate:** `[CD]`.

---

### S9 — `grading_profile`'s fast path is dead, and the slow path walks the tree per sample

**Where:** `pasture3d_road_brush.gd:605-616`.

**Cost.** `_init()` (`:132-133`) unconditionally creates a `Pasture3DRoadOverrides`, so
`road_defaults != null` is **always** true and the uniform fill at `:600-603` is never the final answer.
The loop then runs `p_n_s` times — 5 000 samples on a 5 km road at `alignment_step = 1` — and each
iteration calls `resolved_road_type(s)`, `resolved_lane_count(s)` (which calls `resolved_road_type` again
when lane count is unset, `:213`) and `is_bridge_at(s)`. Each goes through `resolve_chain()`, which
allocates an `Array` and calls `Pasture3DRoadGroup.find_for` and `Pasture3DRoadNetwork.find_for`, both of
which walk the parent chain to the scene root. Roughly six ancestor walks, three `Array` allocations and
four `segment_at` scans **per sample**, and `grading_profile` is called from `_paint_flat_footprint`,
`grade_surface` and `graph_path`.

**Fix.**

1. Hoist the group and the network out of the loop. They cannot change during one `grading_profile` call,
   so `resolve_chain` should take them as arguments — or, better, `grading_profile` should build the
   non-segment part of the chain once and vary only the segment term.
2. Restore a real fast path. The correct test is not `road_defaults != null` but **"does any level of the
   chain vary along this road?"**, which is `segments.is_empty()`. When it is, the uniform fill is exact
   and the loop is skippable entirely — the common case for most roads.
3. Walk the segments once to build a piecewise map from sample index to the covering segment, instead of
   re-scanning `segments` per sample from `segment_at`.

**What must not break.** `graph_path()` (`:1048-1053`) has the same shape over `plan.size()` — up to
25 000 vertices — and must get the same treatment, or S9 fixes the brush's grader and leaves the graph's
paying full price. That asymmetry is the failure mode `grading_profile` was factored out to prevent.

**Gate:** `[CE]`.

---

### S10 — The GDScript footprint pass is O(cells × plan segments)

**Where:** `pasture3d_road_brush.gd:528-536`.

**Cost.** This branch runs whenever `_road_native_is_complete()` is false — that is, whenever the stack is
anything other than exactly one road modifier, which is **precisely the §8 workflow the road-in-a-graph
design exists for** (Road + Graph, Road + Erosion). For a 5 km road with a 50 m corridor at `vs = 1` the
unclipped grid is ~250 000 cells, and each cell runs an interpreted loop over ~25 000 plan segments
(AABB-rejected, but still per segment). The result is only used to set `amp = 0.0` / `profile = 1.0`, and
the road step inside `_run_modifier_stack` then calls the **native** grader, which recomputes the same
nearest-point query in C++ against a spatial index.

**Fix.** Bind the corridor-containment pre-pass natively. `Pasture3DPathGeom` already exists and
`stamp_road_line` already builds one for exactly this (`src/pasture_3d_brush_raster.cpp:2099-2119`); the
missing piece is a `Pasture3DUtil` entry that returns the containment mask for a grid without writing to a
layer. Fall back to the current loop only when the symbol is absent, in line with the project's usual
native/GDScript arrangement.

**What must not break.** The GDScript loop stays as the oracle, not as dead code — `RoadNativeParityGate`
needs a reference implementation, and a definition that lives only in a test drifts from the thing it
defines.

**Gate:** `[CF]`.

---

### S11 — `corridor_half_width` rescans the whole alignment

**Where:** `pasture3d_road_brush.gd:312-327`; `pasture3d_mod_road.gd:239-245`.

**Cost.** `_deepest_structure()` loops `last_alignment.count()` calling `offset_at(i)` — 10 000 iterations
on a 10 km road — with no memoisation against the alignment it just scanned. `corridor_half_width()` calls
it once per active road modifier and is itself called from `_padding()`, `paint_bounds()` (per road inside
`_clear_paint_layers` on every resolve), `build_runtime()` (per road per resolve), `_paint_flat_footprint`
twice, `grade_surface`, and `pick_road_screen_distance` — the last **once per road brush on every editor
click**.

**Fix.** Memoise `_deepest_structure()` on `Pasture3DNodeRoad` against the alignment's `input_digest`,
which already identifies the profile uniquely and is set whenever the alignment is replaced. Compute it
once, in the solve, and store it.

**Note the interaction with S1.** Once `snappedf(_padding(), PAD_QUANTUM)` is in the stamp key, this value
is read on every key computation, so memoising it stops being an optimisation and starts being a
requirement.

**Gate:** `[CG]`.

---

### S12 — The pick path raymarches once per road, and discards its own margin

**Where:** `pasture3d_road_brush.gd:1350` and `:1356`; `src/editor_plugin.gd:776-794`.

**Cost and defect, together.** `_pick_brush_screen` loops every node in the `pasture3d_brush` group. For
each road brush whose screen-space rung misses, `pick_road_screen_distance` runs
`terrain.get_intersection(ray_from, ray_dir, false)` — a full CPU raymarch — against **the same ray**.
Twenty roads means twenty identical raymarches per Select-Brush click, Ctrl-click and sculpt click.

Separately, `effective_margin` (`:1350`) widens the accept threshold to `half_w × pixels_per_metre` so a
wide road stays pickable at distance — and then `_pick_brush_screen` rejects any returned `d` greater than
`radius` (24 or 40 px). Every hit the widening admitted above that is thrown away, so the corridor-aware
margin has no effect on the outcome. This is a live consequence of the picking work on this branch
(`RoadBrushPickGate [RA]`–`[RD]`), which correctly established the two-rung
`POINT_PICK_DISTANCE` / `SURFACE_PICK_FLOOR` scale but left the outer filter unchanged.

**Fix.** Hoist the ground hit into `_pick_brush_screen` and pass the world point down, so one raymarch
serves every brush. Then decide the margin question explicitly: either `_pick_brush_screen` passes each
brush the radius it will actually enforce, or `pick_road_screen_distance` stops widening. **The current
arrangement is the one thing it must not stay** — a widened margin that the caller discards reads as a
feature and is dead code.

**Gate:** extend `RoadBrushPickGate` rather than adding a gate; the fixture is already there.

---

## 5. Invariants — what none of this may break

1. **No `Input.` reference in a road bake kernel.** `RoadJunctionGate [U]` asserts this. S7 is the fix
   most likely to be tempted; it must not be.
2. **Brush/graph parity stays at 0.0000 m.** `RoadGraphGate [K]` measures it. S3, S9 and S10 all touch
   both sides of that comparison and all three must be run against it.
3. **`_assign` must still not fire on an identical re-resolve.** `RoadGraphGate [G]`. S3 widens the
   comparison; it must not weaken it.
4. **An unresolved or unbaked road still produces an empty path, not zeros.** Every consumer answers
   `unreachable`; nothing throws. S3 and S6 both touch the path-building route.
5. **`graph_path()` stays whole-road.** Dirty-rect clipping is internal to layer rasterisation. S7's
   scoping must not leak into the graph's view of a road.
6. **The GDScript oracles stay in production.** S8 and S10 both replace a GDScript body with a native
   one; in both cases the GDScript stays as the parity reference.

---

## 6. Gate plan

Two new gates, plus criteria added to two existing ones. Every criterion below names a **control that
must fail** — a criterion without one cannot distinguish "measured nothing" from "measured well", and
this is a domain where a stale cache and a correct answer look identical.

### 6.1 `RoadStaleGate` — correctness

Two roads crossing on a sloped terrain, one deep cutting, one segment marked as a bridge. Every criterion
asserts the **cache decision**, by instrumenting whether `_paint_spline` ran, not only the height field —
see §2.1 for why an outcome-only assertion can pass by accident.

| # | Claim | Control that must fail |
|---|---|---|
| `[SA]` | After the junction resolve, the minor road's re-bake is a cache **miss**, and its alignment's pinned sample equals the junction elevation exactly. | Restore the narrow `_compute_stamp_key` and this must fail. Assert `snap_to_surface = false` on the fixture, or the accidental key change described in §2.1 makes it pass with the bug present. |
| `[SB]` | A deep cutting's second bake uses a **strictly wider** footprint than its first, and its third uses the same as its second. | Remove `snappedf(_padding(), …)` from the signature: bake 2 replays bake 1 and the widths are equal. Remove the quantisation instead: the width never stabilises and bake 3 differs from bake 2 — that is the other half, and only the pair proves convergence. |
| `[SC]` | A road brush with no road modifier and no deep cut re-bakes **zero** extra times on its first bake. | Restore `_last_corridor_half = 0.0` and its `> +0.5` test: the count goes to one. |
| `[SD]` | Each of — brush override, segment edit, group defaults, network defaults, road-type property — schedules exactly one bake, and the resulting corridor width matches the new value. | Assert per source. A single combined criterion passes when four of the five are wired and one is not, which is the state the code is in today. |
| `[SE]` | Changing `crown_override` alone re-assigns the Road Source's path, and the graph-graded surface moves. | Changing `alignment_step` on a road nothing else references must **not** re-assign — that is `RoadGraphGate [G]`'s property, restated here so S3 cannot be "fixed" by assigning unconditionally. |
| `[SF]` | `road_content_signature()` is stable across a save/reload round trip with no edit. | Put a raw `_padding()` in it instead of the quantised one: the signature churns and every reload is a full re-rasterise. |
| `[SG]` | The chunk host's rebuild digest and the stamp key derive their road-content term from the **same** function. | Change one road-type property that only the mesher reads: both must move together. Two independently maintained lists drift on the first property added. |

### 6.2 `RoadModelGate` — one addition

| # | Claim | Control that must fail |
|---|---|---|
| `[SH]` | Ticking `closed` on a road with an existing spline lengthens the plan by the seam distance, sets `curve.closed`, and produces a `Pasture3DGraphPath` whose closing edge is present. | Untick it: all three revert. Asserting only `_is_closed()` passes today with the bug present, because the flag was never the broken part. |

### 6.3 `RoadCostGate` — counters, not clocks

Counter-based, per §4.2. Fixture: one network, five roads, one junction, one road dragged.

| # | Claim | Control that must fail |
|---|---|---|
| `[CA]` | One drag tessellates each spline **once**. | Revert the memo: the count rises to the number of callers. Then edit a curve and assert the count rises again — a cache that never invalidates also passes the first half. |
| `[CB]` | One resolve calls `build_run()` **once per brush**. | Revert S7's de-duplication: it goes to three or four per brush. |
| `[CC]` | Dragging one road repaints and re-chunks **only** that road and its junction partners, and does not touch `runtime`, `run_ids` or `next_run_id`. | Move `build_runtime` back onto `resolve_junctions`: the scene is marked dirty by a drag, which the criterion asserts directly. |
| `[CD]` | `alignment_digest` allocates no per-point `String`, and a store→check round trip on an unchanged road returns equal. | Perturb one plan point by 1e-3 m: the digest must differ. Equality alone proves nothing — a constant digest passes it. |
| `[CE]` | A road with no segments skips the per-sample loop entirely; a road with one segment enters it and produces different widths inside that range. | Only the pair proves it. The skip alone is equally consistent with a `grading_profile` that stopped resolving anything. |
| `[CF]` | The Road + Graph stack visits each grid cell's containment test once, natively, and its mask is bit-identical to the GDScript oracle's. | Force the GDScript path: the mask must match. Any difference is a second algorithm, not a second backend. |
| `[CG]` | `_deepest_structure()` runs once per solved alignment, not once per caller. | Change the alignment: it must run again. A memo that never invalidates passes the first half and returns a stale corridor width. |

`[SB]` and `[CE]` are the two worth writing first: each is the only criterion in its table that
distinguishes a working fix from one that does nothing at all.

---

## 7. Landing order

Correctness first, then cost, and inside each the order in which one fix makes the next observable.

1. **S1** — the stamp key. Nothing else in this document can be *seen* until this lands, because every
   corrected value is still replayed from a stale block.
2. **S2** — schedule the bakes. Now observable, because of S1.
3. **S3** — the graph's path change test. The same defect on the other side of the wire.
4. **S4** — `closed`. Independent and self-contained; lands whenever convenient after S1 puts it in the key.
5. **S6** — cache the plan. Safe, no semantic surface, and it makes S7 measurable.
6. **S7** — scope the resolve. The largest single win, and the riskiest — read R5 first.
7. **S8** — the digest, now inside a much smaller loop.
8. **S9** — the resolve-chain hoisting, brush **and** graph path together.
9. **S10** — the native containment pre-pass.
10. **S11** — `_deepest_structure` memo. Deferred to here only because S1 makes it a requirement rather
    than an optimisation; if S1's key computation measures badly, pull it forward.
11. **S12** — the pick path. Smallest and most self-contained; last because it changes no baked data.

---

## 8. Deferred — plan decimation

`Pasture3DRidge` decimates its polyline to vertex spacing before rasterising (`pasture3d_ridge.gd:158`),
and the comment at `pasture3d_terrain_brush.gd:5162-5166` names the undecimated ~0.2 m bake as the source
of the O(cells × edges) freeze. `_plan_points()` does not decimate, and `_decimate(pts, step)` already
exists on the base brush taking exactly the array it returns. It looks like free money.

**It is not, and this is why it is deferred rather than folded into S6.** A road's plan polyline
*defines its arc-length metric*. Every `Pasture3DRoadSegment` range, every junction arc length, every
`Pasture3DRoadRoute` waypoint, every `alignment.z` index and every saved `run_id`'s `cum` is measured
along it. Decimating shortens the measured total — chords across a curve are shorter than the chords they
replace — so every one of those moves. Ridge can decimate freely because its polyline carries no
arc-length semantics; the road's carries all of them. This is the same class of error as measuring a
drainage network in grid fractions instead of metres: the units look fine until something downstream is
scaled by them.

If it is taken up later it needs its own phase and its own gate, and at minimum: a **tolerance-driven**
rule (bounded perpendicular deviation, not a fixed stride, which has unbounded angular error on tight
curves), a criterion bounding total-length drift, and a criterion asserting that a segment boundary
authored at 800 m still falls at 800 m. S6's caching captures most of the win without any of that.

---

## 9. Corrections to existing documents

**`PASTURE3D_ROAD_BRUSH_PERF_SPEC.md` §4, "Downstream Cache Protection".** That table states the
`_assign` equality check as a guarantee: that comparing `old.points == new.points` and
`old.heights == new.heights` prevents false `changed` emissions and protects downstream graph node caches.

Half true. It does prevent false emissions, and `RoadGraphGate [G]` holds it to that. What it does not do
is detect a **real** change to the eight fields it never compares, which is S3. The invariant should read
"compares the path's full content digest" once S3 lands, and until then the row overstates what is
guaranteed.

**Same document, §3 Phase 3, "Interactive Drag Coalescing".** Already superseded by
`PASTURE3D_ROAD_PERF_REGRESSION_SPEC.md` R5, which removed the `Input.is_mouse_button_pressed` guards it
asked for and explained why input state cannot live in a bake kernel. S7 replaces the intent with
content-addressed scoping. The Phase 3 text should be struck rather than left to be re-implemented.

---

## 10. Open questions for the author

1. **Should `build_runtime` come off the resolve loop entirely, or run debounced?** S7 proposes an
   explicit bake. The argument against is that a stale `runtime` is invisible until a game loads it. A
   staleness warning on the network covers that, but "the runtime is a deliverable" versus "the runtime is
   always current" is a product decision, not a performance one.
2. **Should `road_content_signature()` include `surface_id`?** It changes no geometry, so the height bake
   does not need it — but `paint_surface` does, and today both are driven off the same refresh. Splitting
   them is cleaner and is one more signature to maintain.
3. **Is the corridor-aware pick margin wanted at all?** S12 says the current arrangement cannot stay.
   Making it real means `_pick_brush_screen` asking each brush for its own radius, which is a wider change
   to a file the picking branch just settled. Dropping the widening is one line. Whether a wide road
   *should* be pickable from further away is the actual question, and it has not been asked yet.
