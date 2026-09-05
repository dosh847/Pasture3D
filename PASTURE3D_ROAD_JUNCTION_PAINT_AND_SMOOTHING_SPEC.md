# Pasture3D Road — Junction Ribbons & Alignment Smoothing

**Document:** `PASTURE3D_ROAD_JUNCTION_PAINT_AND_SMOOTHING_SPEC.md`
**Status:** **P9b BUILT** 2026-09-02 (gate `RoadSmoothGate`, green native and forced-GDScript).
**P9a-0 BUILT 2026-09-04** (§2.2: the junction surface is a polygon, and every road is trimmed to it).
Gates `RoadJunctionPolygonGate` (A–G, the planar kernel) and `RoadJunctionGate` (E, J, L, the wiring);
criterion M is in the polygon gate. Four mutations, all caught — see §2.6.
**P9a BUILT 2026-09-04** — stop bars, crossings, give-way rows, connector ribbons and connector guides
(`Pasture3DRoadJunctionMarkings`, gate `RoadJunctionPaintGate`, criteria A, B, E, F, G, H, I, N, O,
fifteen mutations). **P9a ARM_CONTINUATION is RETIRED, not deferred — see §2.3.**

**Both features of this document are now built.** The §2.5 LOD gap closed 2026-09-05: markings are now
hidden above `Pasture3DRoadChunkHost.MARKINGS_MAX_LOD` (tier NEAR), on the ribbon as well as the
junction — the host built them as a child of the chunk and never touched them again, so every stop bar,
crossing and centre line rendered at 600 m. Gate `RoadMeshGate` [N], two mutations. What is left is not
a phase: the connector overlay's overdraw (§2.4) has not been measured on a real scene.
**P9a-orphans BUILT 2026-09-04** (gate `RoadJunctionOrphanGate`, 7 criteria, 4 mutations) — see §2.6.
**Revised 2026-09-04** — P9a was scoped as markings drawn *on top of* the existing apron disc. Review
against the author's expectation ("a polygon built to connect with the ribbons of every road that
connects to the intersection") found the surface itself in scope. **P9a-0 (§2.2) is new and comes
first**; §2.4's overlay recommendation, SS5's suggested order and the gate in §2.6 are revised to suit.
**References:** `PASTURE3D_ROAD_SYSTEM_PROPOSAL.md` §6.4, §8, §10; `PASTURE3D_ROAD_BRUSH_PERF_SPEC.md`
**Phases:** proposed as **P9a** (junction paint) and **P9b** (smoothing). Both sit after P7b; neither
depends on P8, which remains the only unbuilt phase of the original plan.

---

## 1. Why these two, and why together

They are unrelated features that share one property: **both are finishing work on surfaces the road
system already computes but does not use.** The junction's lane connectors are solved, published and
consumed by the reference lane follower — and never drawn. The alignment's vertical profile is solved,
projected and graded — and never conditioned. Neither feature needs a new solver.

They are specified in one document because they land in the same two files and would otherwise be two
overlapping edits to `pasture3d_road_chunk_host.gd`.

---

## 2. Feature A — the junction surface, its ribbons and its markings (P9a)

### 2.1 What exists today

Read before proposing anything, because most of this feature is already sitting in memory:

| Thing | Where | State |
|---|---|---|
| Lane connectors | `Pasture3DRoadLaneConnector.curve` | **Solved.** A `Curve3D` per legal path through the junction, in WORLD space, tangent-continuous with both lanes at its ends. Carries `turn`, the signed angle, and `allowed_override`. |
| Stop lines | `Pasture3DRoadStopLine` | **Solved.** One per incoming lane: world `point`, `heading` into the junction, `width`, and the arc length. `endpoints()` already returns the two ends of the painted bar. |
| The junction surface | `Pasture3DRoadMesher.plan_footprint` / `.build_footprint` | **Built as a polygon** (P9a-0, 2026-09-04). A triangle fan over the arms' cut ends with kerb returns at the corners, sampling the graded ground rather than sitting at `junction.elevation`. Replaced `build_apron`'s disc; the ground-sampling was right and was kept verbatim. |
| Trimming the approaches | `Pasture3DRoadBrush.junction_skips`, `grade_surface` | **Built** (P9a-0, 2026-09-04). Every arm is trimmed IN THE RIBBON, the major road included; in the GROUND the major road still grades through — see §2.2.2, corrected 2026-09-04. The trim now carries the kerb-return allowance as well as the clearance term. |
| Road markings | `Pasture3DRoadMarkings.plan` / `.build` | **Built, but only along roads.** `plan()` answers in the grader's `u` (signed metres across, positive right); the host calls it per chunk, and `Pasture3DRoadMesher.chunk_spans` explicitly **removes everything inside a junction footprint**. |

So there are two gaps, not one. **Inside a footprint there is a bare grey disc**: the carriageway's edge
lines and centre line stop dead at the trim-back boundary, every stop line is data that nothing draws,
and every connector curve is a path nothing shows. That is the markings gap, and §2.3-§2.4 address it.

But the disc it would be drawn on does not meet the roads either, and that is §2.2.

---

### 2.2 P9a-0 — the junction surface is a polygon, and every road is trimmed to it

**This section is new. It is the first thing P9a builds, because everything else in Feature A is drawn
on the surface it produces.**

#### 2.2.1 Why the disc cannot be made to work

An arm's cut end is a **flat, full-width face** — a chord across the footprint, `2 * half_width` long.
A circle and a chord coincide at exactly two points. So a disc of any radius is simultaneously:

- **too big between the arms**, bulging past the corners of the carriageway onto open ground; and
- **too small at the arm faces**, because a disc of radius `trim` reaches the *middle* of the cut face
  and misses both of its corners, which sit at `sqrt(trim^2 + half_width^2)`.

`Pasture3DRoadMesher._apron_radius()` already documents the second half of this and patches it by
inflating the radius to reach those corners. That comment is worth reading as evidence rather than as a
fix: **it makes the first half strictly worse.** Every metre the disc grows to catch an arm corner is a
metre it also grows in the directions where no road runs. The workaround and the defect are the same
number pulling opposite ways, and no value of it is correct.

A disc is the right primitive for a footprint that must *contain* the arms. It is the wrong primitive
for a surface that must *meet* them.

#### 2.2.2 The other half: the major road is never trimmed

`Pasture3DRoadBrush.grade_surface` and `junction_skips()` both carry the same rule, deliberately and
with the same comment:

> only a road that is NOT the major one stops at the footprint. The major road keeps its own profile and
> paves straight through

That rule is why an intersection today is **not a shared surface at all**. It is the major road's own
ribbon, running through at full width, with the minor arms terminating into its flank and a patch laid
beside them. At a 4-arm crossroads where every road resolves to the same `priority`, `major_index` falls
to whichever road the solver walked first — so which road paves through is arbitrary, and the other
arms dead-end into it.

**A polygon that connects to the ribbons of every road requires every road to be trimmed, including the
major one.** That is the substantive behaviour change in P9a-0, and it retires three things:

| Retired | Where | Why it goes |
|---|---|---|
| The `is_major` exemption in the grading skip | `pasture3d_road_brush.gd`, `grading_profile` | **Retired 2026-09-04**, on the third attempt. Keeping it let the major road pave a second surface through the polygon; retiring it alone left NOTHING grading inside a footprint and buried every intersection. What makes retirement correct is `grade_junction_footprints`, added with it — see §2.2.3. |
| The `is_major` exemption in `junction_skips()` | `pasture3d_road_brush.gd` | **Retired 2026-09-04.** Every arm's ribbon stops at the footprint and the polygon covers what they leave: mesh meets mesh, both at the junction's elevation. |
| `_apron_radius()` entirely | `pasture3d_road_network.gd` | It exists only to make a disc reach a cut face. There is no disc. **Deleted 2026-09-04.** |

**THE TWO EXEMPTIONS ARE NOT A MATCHED PAIR.** This document said they were, twice — the comment in
`junction_skips()` read "retired in BOTH or in neither" — and that framing broke the junctions in both
directions on 2026-09-04, first by keeping them together and then by retiring them together. They are two
consumers with two different owners:

* the **ribbon** stops at the footprint for every arm, because the junction POLYGON covers what it leaves;
* the **ground** inside the footprint is graded by the major road, because nothing else can.

A rule that reads one and infers the other cannot see either failure. Criterion L asserts the split: the
major road leaves a ribbon gap AND is not skipped in the grader, and the minor road leaves a ribbon gap
AND is skipped. Both mutations fire (M16, M17 below).

**These two exemptions had to be gated separately.** They are a matched pair, so the obvious assumption
is that one criterion covers both — and the build proved otherwise. Reverting only the `junction_skips`
half failed criterion L on the ribbon-gap assertion; reverting only the `grade_surface` half passed it
outright, because nothing read the grader's own `skip` mask. L now asserts both consumers, and the
grader half is read as the `skip` that `grading_profile` *returns* rather than as the guard that
produces it. See [[component-gates-miss-wiring]]: a value that lives in two places is fixed in neither
until both are asserted.

**The trim-back is now two terms, and E and F turn the second one off.** A trim is the clearance
`other_half / sin θ` plus the kerb-return allowance `radius / tan(φ/2)`. Criteria E and F were written
for the closed form and would have measured the sum, unable to say which term was wrong; they now
resolve with `default_corner_radius` at zero and assert the clearance alone, and E asserts the allowance
separately at a square crossing, where `tan(45°) = 1` makes it exactly the radius — a figure the gate
states in advance instead of recomputing the code under test.

#### 2.2.3 The junction owns its own surface — **BUILT 2026-09-04**

The major road used to grade the footprint's ground and the polygon used to be draped on its alignment.
Both are gone. The reason is a case this document never considered: **two roads of the SAME TYPE**, which
is the commonest arrangement there is and the one in the author's test scene.

Same type means the same `priority`, so they TIE. The solver breaks the tie with `if pr > best_priority`
— strictly greater, so the first road *walked* wins — and that is `major_index`, which is scene order. So
the intersection took its crown, its grade and its camber from whichever road happened to sit higher in
the tree, and reordering the nodes changed the shape of the junction. Reported as "one is overriding the
other". It is the same fault `corner_radius` already refuses to run on (§2.2.1: scene order is "tolerable
for a height and not for visible geometry") — the ground was simply still running on it.

The fix is not a better tie-break. It is to stop asking the question:

1. **Every arm is trimmed**, ribbon and ground alike, with no exemption for anybody.
2. **The polygon's boundary vertices take their heights from the ARMS.** Every boundary vertex lies on
   some arm's cut face, and that face is the last cross-section of a ribbon that stops there — so the
   vertex height is that ribbon's own height at that across-offset, and the polygon meets each ribbon
   exactly by construction rather than by a tolerance. A fillet vertex lies on no cut face and blends the
   arms by inverse square distance to theirs.
3. **The junction grades the ground inside its footprint**, to the same surface, interpolated over the
   same triangle fan the mesh is built from. Ground and mesh are one definition read twice
   (`Pasture3DRoadNetwork.junction_surface`), not two that agree to a tolerance — and a tolerance between
   them is road surface showing through the terrain.

Priority keeps exactly what priority is for: it sets `elevation`, the height the intersection sits at,
and picks the material. It no longer decides the SHAPE, so a tie stops being visible at all.

**Three details that were each wrong first.**

*The cut face is at `trim`, not at the centre.* On a road with a grade the two differ by grade x trim —
0.68 m on the gate's fixture — which is a step against every ribbon the polygon is meant to join.

*The cut face needs its CENTRELINE vertex.* A face represented by its two corners is a chord across the
ribbon's crown, so the polygon sat `crown x half` below the road at the middle of every approach: 0.20 m
on a 0.05 crown and a 4 m half-width, a crease across each arm. The extra vertex is collinear in plan and
changes no outline criterion; in section it is the whole difference.

*The cross-sections are STORED, not read back.* An alignment is solved against the surface entering its
own bake, which includes whatever the other roads at this junction have already graded — so re-reading
one gives a different answer depending on who baked first, and the shape wobbled with scene order by
0.084 m even after everything above. `arm_z`, `arm_banks` and `arm_crowns` are resolved once from one
snapshot and every consumer reads the same numbers. Reconcile, don't rebuild.

**What does NOT change: the major road still decides the height.** `build_apron`'s ground-sampling
argument is untouched, and is the reason the polygon is not flat at `junction.elevation` either. The
major road's solved profile remains the height field the polygon samples, and `pin_for()` still pins the
minor arms to it. Priority stops deciding *who gets trimmed*; it keeps deciding *what height the
intersection sits at*. Those were always two different jobs sharing one flag.

#### 2.2.3 The polygon

Same two-stage split as the markings kernel, and for the same reason — everything that can be wrong is
wrong in the plan:

```
plan_footprint(junction, runs) -> PackedVector2Array   # world XZ boundary, assertable as numbers
build_footprint(boundary, ground_sampler)              # triangles
```

`plan_footprint` walks the arms **in angular order around `junction.center`** and emits, per arm:

1. the arm's two cut-face corners, at `center + dir * trim` offset by `+/- half_width` across; then
2. a **corner fillet** from this arm's trailing corner to the next arm's leading corner.

Angular order is what makes this N-ary for free: three arms, four arms and a five-way all walk the same
loop, and the boundary is closed by construction. It is also the one thing the current code has never
been asked to do — see the note in §2.6 on why no junction in `demo_road_network.tscn` has more than
two participants.

The fillet is the only shape decision, and it is **a circular arc tangent to both cut faces**. A straight
chord between corners is cheaper and reads as a chamfer, which is wrong for anything but a slip lane; an
arc is what a real intersection has and costs one `atan2` per corner.

**Which radius, when the arms disagree (RESOLVED 2026-09-04).** `corner_radius` is a new field on
`Pasture3DRoadType`, resolving through the normal Segment → Brush → Group → Network chain like every
other road setting. At a junction the arms may resolve different values, so:

1. **Priority picks it.** The `corner_radius` of the **highest-`priority` participating road** wins. A
   trunk road meeting a lane should turn with the trunk road's sweep, and priority is already the field
   that says which road the intersection is built around — the same field that decides `elevation`.
2. **On a tie, the group's or the network's default wins**, resolved through the same chain from the
   junction outward.

**Do not implement step 1 as `effective_major()`.** It looks like the same question and is not.
`major_index` resolves a priority tie by falling to whichever road the solver **walked first** (see
`_resolve_group`: `pr > best_priority` keeps the first of equals), which is scene order. That is
tolerable for `elevation`, where tied roads are at the same height anyway and the choice is invisible.
It is **not** tolerable for a corner radius: two equal-priority roads with different `corner_radius`
would give the intersection a visibly different shape depending on node order, and reparenting an
unrelated road would silently change it. Step 2 exists precisely to make the tie **deterministic and
authored** instead of incidental — which is why the tie-break is a lookup, not a winner.

A per-junction `corner_radius_override` follows the `radius_override` convention already on
`Pasture3DRoadJunction`: negative means "no opinion, use the resolved one".

**Degenerate cases the plan must answer in numbers, not in a rendered frame:**

- **Two arms only** (a road crossing another at an acute angle, or a bend authored as a junction): the
  boundary is still four corners and two fillets. Nothing special-cases arm count.
- **Overlapping cut faces** at an acute crossing, where `trim = other_w / sin theta` grows large enough
  that two arms' faces intersect. The boundary must fall back to the **convex hull of the corners** when
  that happens, or the polygon self-intersects and the triangulation is garbage. Detect it on the plan,
  not on the mesh.
- **A fillet radius larger than the gap between two arms.** Clamp to the largest arc that fits; do not
  emit a reversed arc.

#### 2.2.4 Cost

One polygon per junction per bake, tens of vertices, built in the same `build_junction_surfaces` loop
that builds the aprons today and writing into the same `Junction_<id>` mesh instance. No new host, no
new pass, no per-frame work. The trimming change is free — it removes an `if`.

---

### 2.3 The one real design decision: `u` does not exist at a junction

`Pasture3DRoadMarkings.plan()` works because a road has a single across-axis. A junction has three or
more, and no cross-section at all. **Do not try to generalise `plan()`.** The junction kernel answers in
WORLD space, and that is the difference that keeps both kernels simple.

Add `Pasture3DRoadJunctionMarkings` as a second pure kernel with the same two-stage split and the same
reason for it — everything that can be wrong is wrong in the plan, and the builder only extrudes:

```
plan_junction(junction, roads) -> Array[Primitive]     # world-space, assertable as numbers
build_junction(primitives, ground_sampler)             # triangles
```

Three primitive kinds, and no more:

- **`STOP_BAR`** — **BUILT 2026-09-04.** Straight from `junction.stop_lines`. Zero derivation:
  `endpoints()` already gives the two ends and `width` gives the span. This is the cheapest of the three
  and the most visible.

  Two things the build settled that the spec had not said. **The bar sits BEHIND the hold point**, not
  centred on it: a driver whose nose is on `point` has the whole bar behind them, and painting half of
  it inside the junction puts that half where it can no longer be read. And **the paint takes its height
  from the surface, not from the stop line.** `stop_line.point` carries the road's centreline elevation,
  which is a crown ABOVE the lane the bar is painted across — 0.05 m by default, ten times
  `MARKING_LIFT` — so a bar built at the published height sinks into the road at its middle. The builder
  takes an optional `Callable(Vector2) -> float`, and the host passes `Pasture3DRoadMesher.surface_height`,
  the same sample `build_footprint` takes for the surface. Paint and surface come from one sampler or
  they step apart wherever the road is not flat.
- **`ARM_CONTINUATION`** — ~~the arm's edge lines and divider, extended from the trim-back boundary to
  the footprint edge~~ — **RETIRED 2026-09-04, because P9a-0 removed the gap it was for.**

  The gap was the DISC's. A disc was sized by the WIDEST arm's trim, so every narrower arm's ribbon —
  and its markings with it — stopped short of the surface edge by the difference, and a continuation was
  needed to cover that. The polygon passes THROUGH each arm's own cut face, so each arm's ribbon now
  ends exactly on the boundary. Measured on a crossroads of a 4-lane and a 1-lane road, whose trims
  differ by 5.25 m: the gap is **0.0000 m** at the centreline and at the edge line, on all four arms.

  This is worth stating rather than quietly dropping, because the spec's own build order (§4) predicted
  that P9a-0 would *reposition* the markings items. For this one it did more than reposition it. The
  interior of a real intersection is unmarked too, apart from the three kinds that remain, so continuing
  lines across it would not be finishing this item — it would be inventing a different one.
- **`CROSSWALK`** — **BUILT 2026-09-04.** Continental bars, running along the direction of traffic and
  spread across the carriageway, set back beyond the stop bar. Two decisions worth recording. It spans
  the **carriageway**, from `lanes[0].right_edge` to `lanes[-1].left_edge`, never `half_width()` — a
  shoulder is not a lane and is not walked to, and the two agree on any road without a shoulder, which
  is most fixtures (this is why gate H's control widens the shoulder alone). And the bar **count** grows
  with the road rather than the bar width: a fixed count spread across any width makes a one-lane
  crossing read as a few fat blocks and a four-lane one as pinstripes.

- **`GIVE_WAY`** — **BUILT 2026-09-04.** A row of triangles across the carriageway of an arm whose
  priority is below the junction's highest, apex pointing back at the approaching driver, set back
  beyond the crossing. Suppressed entirely under `SIGNALS`: the lights say who goes, and a painted
  triangle contradicting a green light is worse than no marking. An unknown priority reads as the
  LOWEST, not the highest — a participant the junction has no record for must not silently acquire
  right of way.

- **`CONNECTOR_GUIDE`** — **BUILT 2026-09-04.** A dashed line along `connector.curve`, emitted only for
  connectors whose `turn` is `LEFT` or `RIGHT` **and** which must give way (`junction.yields_to(id)`
  non-empty — the directed half of the conflict list, which is the one that means "this movement is the
  one that has to wait"). A guide on every connector paints a junction solid white; on the gate's
  fixture that is 12 legal movements narrowed to 6.

  The dashes come from `Pasture3DRoadMarkings.runs()` — called, not reimplemented, so a guide dash and a
  lane dash cannot drift apart. The curve is sampled with `tessellate_even_length` rather than
  `tessellate`: the adaptive one puts its samples where the CURVATURE is, which is exactly where a dash
  needs even spacing, and a dash measured along an unevenly sampled polyline is longer through the
  straight part of a turn than through its apex.

- **`CONNECTOR_RIBBON`** — **BUILT 2026-09-04.** One lane wide along each legal movement, the width
  taken from the arm's own cross-section rather than from an option, so a junction of a motorway and a
  lane does not draw both at the same width. §2.4's overlay recommendation stands: this sits ON the
  polygon, it does not replace it.

  **The lift is per KIND**, because the three things are stacked rather than side by side: surface,
  then ribbon at `RIBBON_LIFT`, then paint at `MARKING_LIFT`. `RIBBON_LIFT` is derived from
  `MARKING_LIFT` rather than written as a second constant, so the ordering stays true if either moves.
  A single lift would put a guide inside the ribbon it is painted on, and coplanar geometry is decided
  by float precision, not by draw order.

`allowed_override == OFF` emits nothing for that connector, and no guide. A connector that is not legal
must not be painted as an invitation.

### 2.4 Ribbons from connector curves

The user's framing — "use our intersection curves to build ribbons" — is buildable directly:
`Pasture3DRoadMesher.ring()` is a pure function of a plan polyline plus cumulative arc length, and a
`Curve3D` tessellates to exactly that. So a connector ribbon is `ring()` driven off
`curve.tessellate_even_length()` with a one-lane cross-section.

**Recommendation: overlay, do not replace.** Keep the apron as the surface and lay connector ribbons on
it at `DEPTH_LIFT`, rather than replacing the disc with a union of ribbons. Three reasons, in order of
how much they cost to learn the hard way:

1. A union of ribbons has holes wherever no connector runs — the corners of a crossroads — and the
   terrain shows through. The §2.2 polygon has no holes by construction, and unlike the disc it also
   has no overhang: its boundary IS the corner the ribbons would have left bare. **This is the reason
   the overlay recommendation survives P9a-0 rather than being replaced by it.** The polygon is the
   surface; connector ribbons stay an overlay on it.
2. Overlay is the pattern P5a already proved works for tier FAR paint (overlay-not-base is recorded as
   the reason its edges work).
3. It is reversible. A connector ribbon that looks wrong can be switched off without leaving a hole.

The cost is overdraw across the footprint, bounded by the number of connectors, and NEAR-tier only.

### 2.5 Where it lives, and LOD

`Pasture3DRoadChunkHost` already builds one `MeshInstance3D` per junction (`Junction_<id>`, see the
apron loop) and already owns the tier mapping. Junction paint is one more mesh per junction from the
same loop, at **tier NEAR only**, matching P5c: markings are unreadable at MID and absent at FAR, where
the road is terrain paint anyway.

**Built 2026-09-05.** The tier is `MARKINGS_MAX_LOD`, stated once on the host and not exported — it is
not a preference, it is the tier markings belong to. Both marking builders return the node they made and
the chunk record carries it, so the LOD swap that already changes `mi.mesh` also sets its visibility;
markings follow the ribbon's tier rather than a distance of their own, because two thresholds over one
distance disagree inside the hysteresis band and leave a stripe hanging off a chunk that coarsened under
it. Beyond `far_distance` nothing was needed: markings are children of the chunk, which is hidden whole.

The ribbon's markings had the same gap and are fixed by the same mechanism — P5c is where the rule was
stated and neither builder had ever read it.

Lift: `MARKING_LIFT` **on top of** the ribbon's lift, never instead of it — the same rule the road
markings follow, and for the same reason (coplanar geometry is decided by float precision, not by draw
order).

### 2.6 Gate — `RoadJunctionPaintGate`

Every criterion below is decidable from numbers; none needs a rendered frame.

**Fixtures: use the real ones, they exist.** `project/demo_road_network.tscn` resolves genuine N-ary
junctions today — clustering works and is exercised:

| Fixture | `road_keys` | `trim_backs` | `radius` |
|---|---|---|---|
| `Road+Road1+Road2+Road3@191,55` | 4 arms | `[5.691, 5.691, 6.413, 6.413]` | `6.413` |
| `Road+Road1+Road2@-156,-221` | 3 arms | `[6.042, 5.122, 6.042]` | `6.042` |

Both are detected, and the differing trim-backs within one junction are the useful part: they are what a
single radius cannot represent, so these two records alone falsify the disc. Criterion K can therefore be
stated against **measured project data** rather than a synthetic rig — for the 4-arm case, an arm with
`trim = 6.413` and `half_width = 4.0` has its cut-face corners at `sqrt(6.413^2 + 4^2) = 7.559 m`, which
the `6.413 m` disc misses by **1.146 m**. That number is the gate's expected failure magnitude when the
disc is restored.

Keep a synthetic 45/135-degree rig as well, but only for criterion J's convex-hull fallback: no junction
in the project crosses acutely enough to make two cut faces overlap, so that path is the one branch real
data does not reach.

#### The junction polygon — **BUILT 2026-09-04**, gates `RoadJunctionPolygonGate` + `RoadJunctionGate`

Split across two gates on purpose. `plan_footprint` is pure planar geometry, so A–G and M are decidable
from numbers with no terrain, no brushes and no bake — they run in under a second and say exactly which
number is wrong. J and L need a real network to prove the wiring, so they live in `RoadJunctionGate`
beside the fixture that already exists there. A single gate would have made the planar claims pay for a
terrain they do not need, and would have let a wiring failure read as a geometry failure.

The corner radius resolution (M) is asserted three ways, not two. Priority decides; a tie **that
disagrees** falls to the network default; and a tie **that agrees** keeps the roads' shared value. The
third is the one that is easy to leave out, and without it the criterion passes on an implementation
that ignores `corner_radius` whenever two priorities match. Each case is resolved twice with the runs
reversed, because the tie must not be answered by scene order — see §2.2.3.

| # | Mutation | Caught by |
|---|---|---|
| 1 | Restore the `is_major` exemption in `junction_skips()` only | L — the major road's ribbon gap goes empty |
| 2 | Restore the `is_major` exemption in `grade_surface` only | L — the grader's returned `skip` is clear at the junction cell. **Passed before L was extended to read it**, which is what put the second half in. |
| 3 | Drop the fillet allowance from the trim-backs (`trims[gi] += 0.0 * allow[gi]`) | E — the kerb return buys itself no room, and its own control fires too |
| 4 | Resolve a disagreeing tie by first-seen instead of the default | M — wrong value, and it changes when the roads are reversed |

The gap J was written for is still measurable: at the crossing fixture the cut corners sit 0.770 m
outside the disc that used to be the surface. J states that number as its control, so a regression to a
disc fails rather than quietly re-opening the hole.

#### Junction stop bars — **BUILT 2026-09-04**, gate `RoadJunctionPaintGate`

| # | Mutation | Caught by |
|---|---|---|
| 1 | Centre the bar on the hold point instead of setting it back | B — the midpoint is off by half the bar |
| 2 | Drop the `detected` / `disabled` guard | N, both halves |
| 3 | Builder ignores its sampler | O, and O's own control fires with it |
| 4 | Run the bar ALONG the road rather than across it | B — four "behind the hold point" failures plus the perpendicularity check |

A's real content is the COUNT, stated in advance from the fixture: two two-lane roads crossing give four
incoming lanes and therefore four bars. An outgoing lane has nothing to hold for, and a bar across one
tells traffic leaving the junction to stop in it. Its control is that both roads appear — four bars all
on one road satisfies the count and means the kernel painted one road's two arms twice.

#### Junction crossings and give-way rows — **BUILT 2026-09-04**, gate `RoadJunctionPaintGate`

| # | Mutation | Caught by |
|---|---|---|
| 5 | Span the formation rather than the carriageway | H — 10.5 m of a 7.0 m carriageway |
| 6 | Drop the crossing's setback so it overlaps the stop bar | H — the ordering along the approach |
| 7 | Emit a give-way row on every arm | I — two yielding roads, and the major road among them |
| 8 | Let signals stop suppressing give-way | I |
| 9 | Point the give-way apex INTO the junction | I's apex check. **Survived the first round**, when I asserted only WHICH road carried a row. |
| 10 | Drop the give-way setback so the row lands on the crossing | I's ordering check |

**A gate can report PASS while measuring nothing, and this one did.** A typed-array assignment threw
inside the fixture, three criteria returned before reaching an assertion, and the summary said PASS with
zero failures — the engine error was the only sign, in a log nobody reads when the last line is green.
Each criterion now records that it RAN TO COMPLETION and the summary fails for any that did not. Worth
generalising to the other gates: `_fail == 0` is only trustworthy alongside "and every criterion
finished". See [[bench-gate-practices]].

#### The junction's own surface — **BUILT 2026-09-04**, gate `RoadJunctionGate` [L], [P]

| # | Mutation | Caught by |
|---|---|---|
| 16 | Skip the major road in the ground with nothing grading the footprint | P — the ground is left at raw height |
| 17 | Skip nobody in the ground | L — the minor half |
| 18 | Return no arm faces, so the polygon is flat at the junction elevation | P — 0.80 m step at the cut faces |
| 19 | Read the cut faces at the junction CENTRE rather than at the trim | P's independent reference, at 0.68 m. **Survived the first round**: `arm_z` is both the polygon's input and its expected value, so the join check was satisfied circularly, and an "is it at the elevation" discriminator did not separate it either. Only the road's own alignment did. |
| 20 | Drop the cut face's centreline vertex | P — 0.20 m, the crown chorded |

**The circularity in 19 is the lesson.** A criterion that checks a derived value against the number it
was derived from asserts only that the derivation is a function. It needs a reference from outside the
chain — here the road's alignment, asked where the ribbon ends.

#### Connector ribbons and guides — **BUILT 2026-09-04**, gate `RoadJunctionPaintGate`

| # | Mutation | Caught by |
|---|---|---|
| 11 | Guide every legal movement | E — the straight-with-priority control, and the subset check |
| 12 | Paint forbidden movements | F, both halves |
| 13 | Fix every ribbon at 3.0 m instead of the lane's width | G |
| 14 | Snap a dash's START to the nearest tessellation sample | E's painted-length check. **Survived the first round**, when E asserted only WHICH movements were guided. |
| 15 | Snap a dash's END as well | the same check, at 0.23 m rather than 24.9 m — worth keeping both, since the small one is the one a tolerance would swallow |

**Adding a kind broke two older criteria, silently in principle.** A and B read `plan_junction()` as
"the stop bars" — true when stop bars were the only kind. Once the plan carried five kinds, B indexed
`stop_lines[i]` with `i` running over 440 primitives and threw on every iteration past the fourth. It
was caught only because criterion B then failed to record that it had run (see the completion check
above). Both now filter by kind. The general point: a criterion that reads a whole collection is
asserting something about its CONTENTS as well, and that second claim is invisible until the collection
grows.

**The connector id is on the primitive, not just the road and lane.** One lane feeds several movements,
so `road:lane` cannot tell a left turn's paint from the straight-ahead's — E's control could not be
written without it, and it read as a false failure until the id was added.

#### Orphaned junction records — **BUILT 2026-09-04**, gate `RoadJunctionOrphanGate`

Shipped ahead of P9a-0 because it is independent of the polygon and because the polygon could not be
judged against a viewport carrying thirteen stale red rings.

**Two causes, both fixed.**

1. **Nothing ever pruned.** `resolve()` kept every undetected prior for ever, reasoning that the roads
   may be dragged back together and discarding the overrides in between would be a silent loss. That is
   right about the *overrides* and wrong about the *record*: a stale junction nobody overrode has
   nothing to restore, since every field on it is solver output the next detection recomputes
   identically. `demo_road_network.tscn` had reached **thirteen undetected records, none of which
   carried a single override**, and `junction_gizmo.gd` draws undetected records in red by design — so
   they showed up as intersections that would not go away short of deleting the road network.
   Now: a stale record is kept only when `Pasture3DRoadJunction.has_authored_override()` is true.
2. **`_match_prior` demanded an exact participant set**, which is right for a junction that MOVED and
   wrong for one that GAINED OR LOST AN ARM. Adding a fourth road to an authored three-way failed the
   match, so the resolve emitted a new record and orphaned the old one, losing its overrides and
   creating precisely the stale record in (1). `Road+Road1+Road3@187,55` is the live 4-arm junction from
   before `Road2` joined, orphaned half a metre away. Now: matched on **participant overlap plus
   proximity**, largest overlap first, distance then index breaking ties.

**Minimum overlap is two, and that is load-bearing.** One shared road is not evidence of identity — a
junction of A+B and a separate junction of A+C along the same road share exactly one participant, and at
a threshold of one the nearer could claim the other's record *and its overrides*. Two is the smallest
overlap that can only mean the same crossing, because two roads cross each other at a given place once.

**One consequence that had to be handled with it:** `major_override` is an **index** into `road_keys`.
Once a prior can match despite a changed participant list, an index carried across unchanged quietly
comes to mean a different road — "this road has right of way" silently becoming "that one does". It is
now remapped by key on reconcile, and resets to -1 when the road it named has left the junction.

**Mutation results** (each fires on a different criterion, so none is redundant):

| Mutation | Fires |
|---|---|
| Keep every stale record (the old rule) | A |
| Exact participant-set match (the old rule) | D, E |
| Drop the `major_override` remap | G |
| Lower the minimum overlap to one | F |

A and B are deliberately the same fixture differing only in whether an override was authored: a prune
that deleted everything passes A, one that deleted nothing passes B, and only the pair distinguishes
"measured nothing" from "measured well".

**A gate that catches its own blunt fixture.** [G]'s first assertion originally passed on the bug — the
reordered participants happened to leave the overridden road in the slot it already occupied, so a stale
index was still accidentally correct. The gate now asserts that the road actually CHANGED slot before
testing that the override followed it, and reports "cannot tell a remap from luck" when it did not.

| # | Claim | Control that must fail |
|---|---|---|
| A | A 4-arm crossroads emits exactly one `STOP_BAR` per incoming lane. | Make one arm one-way outbound: its bars disappear and the count drops by exactly its lane count. |
| B | Each bar's midpoint equals its `stop_line.point` to 1e-4 m, and its normal is `heading`. | Change `radius_override`: the trim-back moves and every bar moves with it. A bar that stayed put is reading the wrong boundary. |
| C | A one-way arm gets **no divider continuation** (no opposing traffic), but still gets edge lines. | Flip it two-way; the divider appears. |
| D | Continuation offsets equal `Pasture3DRoadMarkings.plan()` on that arm, exactly. | Change `divider_type`; both move together. Asserting a literal offset here would drift with a copied formula — compare against the kernel. |
| E | **(BUILT)** Guides are emitted only for turning connectors that must give way, and the dashes are `Pasture3DRoadMarkings.runs()`' own. | Guide every legal movement: the straight-ahead-with-priority control fires, and the subset check with it. **And a separate mutation for the dashes** — snapping a dash to the nearest tessellation sample leaves the RIGHT movements guided at the WRONG length, which every other assertion in E passes. That one survived the first round. |
| F | **(BUILT)** `allowed_override = OFF` removes that connector's ribbon **and** its guide. | INHERIT restores both. Both halves are asserted separately: a kernel that filtered guides but not ribbons would still paint the forbidden turn, in the more visible of the two. |
| G | **(BUILT, restated)** A connector ribbon lands on its own connector's endpoints and is one lane wide. | The original wording asked for exact-float tangent continuity with the arm ribbons, citing P5b. That bar is met **by construction** and the criterion says so instead of re-measuring it: the ribbon is sampled off `connector.curve`, which the lane solver already built tangent-continuous with both lanes, so there is no second arc-length accumulation to disagree. What the sampling CAN lose is the endpoints — an even-length tessellation that dropped or overshot the last point would detach the ribbon at exactly the join the curve exists to make — so that is what G asserts. Control: fix every ribbon at 3.0 m and the width check fires. |
| H | **(BUILT)** A crosswalk emits one ladder per arm, its bars spanning exactly that arm's carriageway (not its shoulders), sitting outside the stop bar. | Widen `shoulder_width` alone: the ladder must NOT change width. A ladder that grew is measuring `half_width` instead of the carriageway. |
| I | **(BUILT)** `GIVE_WAY` triangles appear only on arms that lose priority and whose `effective_control()` is not `SIGNALS`, with the **apex pointing away from the junction** and the row outside the crossing. | Switch the junction to `SIGNALS`: every triangle disappears. Raise the losing arm's `priority` above the other: they move to the other arm rather than vanishing. **Reverse the apex**: the road/no-road assertions cannot see orientation, and a correct row turned round aims the instruction at the traffic already leaving — that mutation survived until the apex check was added. |
| J | **(P9a-0)** For a 4-arm 90-degree fixture, `plan_footprint` returns a boundary whose vertices are exactly the 8 cut-face corners plus 4 fillet arcs, in angular order, and the polygon is simple (no self-intersection) and closed. | Feed the 45-degree fixture, where `trim = w / sin 45` is larger: the boundary must still be simple. If the convex-hull fallback is missing this is where it self-intersects. |
| K | **(P9a-0)** Every arm's cut face lies exactly on the polygon boundary — both corners of every arm are vertices of the returned boundary, to 1e-4 m. This is the whole claim of the feature: the surface MEETS the ribbons. | Revert `build_apron`'s disc: the corners now sit off the boundary by `sqrt(trim^2 + half_width^2) — trim`, which for the 8 m fixture is a number the gate can state in advance (about 1.66 m). A gate that cannot distinguish the disc from the polygon is measuring nothing. |
| L | **(P9a-0)** Every arm is trimmed, major and minor alike, in the ribbon and the ground. | Skip nobody and the lumpy scar the trim exists to prevent comes back. L alone is satisfied by a build that trims everybody and grades nothing — the burial — which is why P exists. |
| P | **(BUILT)** The junction grades its own footprint, to the polygon's own surface, and swapping the two roads' scene order changes the height field by nothing at all. The fixture's roads share one road type, so they TIE. | Four controls. Drop the arm faces and the polygon goes flat (0.80 m step). Read the cut faces at the junction centre and they land 0.68 m from where the ribbons end — caught only against the road's own alignment, since `arm_z` is otherwise both the input and the expected value. Drop the centreline vertex and the crown is chorded (0.20 m). And the tie itself is asserted, or the criterion is measuring the easy case. |
| N | **(P9a stop bars)** A `disabled` or undetected junction emits no primitives at all. | Remove the guard: a crossing the author marked as an overpass paints stop bars on a road with nothing crossing it. |
| O | **(P9a stop bars)** `build_junction` puts every vertex on the surface its sampler describes, and falls back to the primitive's flat published height only when given none. | Make the builder ignore its sampler. The control is the fallback itself: build the same primitive both ways and the two answers must DIFFER, or the criterion cannot tell "the sampler was used" from "the sampler agreed". The sampler in the gate is a ramp, not a constant, so a builder that sampled once and reused the answer fails too. |
| M | **(P9a-0)** The fillet radius equals the highest-priority arm's resolved `corner_radius`; when the top priority is tied, it equals the network default instead. | Give two tied arms different `corner_radius` values and **reorder them in the scene tree**: the resolved fillet must NOT change. If it does, the tie is falling through to `effective_major()` and scene order is deciding geometry. |

---

## 3. Feature B — alignment smoothing (P9b) — **BUILT**

> **As built, 2026-09-02.** `smooth_radius` sits on `Pasture3DNodeRoad` beside `alignment_step` (open
> question 2 below answered: per-brush, not inherited — "this one road is bumpy" is a fact about a
> stretch of road, not a class of road). Both `solve_with_plan` call sites in `pasture3d_road_brush.gd`
> pass it, and `alignment_digest` hashes it. The pass is a final stage of `road_align_solve` in
> `src/pasture_3d_road_grade.cpp`, mirrored by `Pasture3DRoadAlignmentSolver._smooth_profile` as the
> oracle. Two corrections the build made to the text below:
>
> - **Criterion B's threshold was wrong, not the implementation.** The spec asked for "<10% attenuation"
>   of the long band; a triple box of that width provably takes 10.9%, and the implementation returned
>   10.7%. The gate now asserts against the kernel's closed-form transfer function, which is strictly
>   stronger — it catches a two-pass filter, which any round number lets through.
> - **Criterion G's tolerance is 1e-3 m, not 1e-5.** `RoadNativeParityGate` [G] already sets that bar for
>   this exact comparison, because the native solve carries a convergence break at 1e-4 m that the
>   GDScript body does not. The two paths differ by ~1.3e-4 m before smoothing is involved at all, so
>   1e-5 was asserting the wrong thing. Measured divergence with the pass on: 1.3e-4 m against 2.17 m of
>   movement.

### 3.1 Where it goes — the user's guess is right, with one correction

The pipeline in `pasture3d_road_brush.gd` is:

```
_resample_plan(...) -> solve_with_plan(...) -> alignment.z -> "align_z" -> native grader -> terrain
                                              ^^^^^^^^^^^^
                                              here
```

Smoothing `alignment.z` after the solve and before the grade is exactly "after grading the curve, before
the landscape deformation" as asked.

**It ships NATIVE.** Road editing is already slow next to comparable tools, and this pass runs on every
drag of every spline point — a GDScript filter over a 2 km road at a 1 m step is 2000 samples times
three box passes times a re-projection loop, per interactive bake, and it would be paid by every road
whether or not the feature is switched on. There is no reason to pay it: `Pasture3DUtil` already
exposes `road_align_solve` and `road_align_solve_with_plan`, both of which take an **`opts` Dictionary**.
`smooth_radius` goes in `opts`, so this needs no new binding signature and no new entry point — the
native solver grows a final stage and the existing call site passes one more key.

This does mean the pass exists twice, in C++ and in the GDScript solver. That is not the R7 trap; it is
the arrangement R7 established. `force_gdscript` is already threaded through `solve`,
`solve_with_plan`, `plan_curvature` and `superelevation` precisely so the GDScript body can serve as an
independent oracle, and the smoothing pass must be threaded the same way or a forced solve returns a
half-oracle — a profile smoothed by neither implementation, which would compare equal to nothing.

What would have been the R7 trap is putting the smoothing in `pasture_3d_road_grade.cpp` instead of the
solver: the grader is downstream of the projections, so a smoothing pass there could not re-apply pins
or the gradient limit without duplicating them too. It belongs in the solver, on both sides.

**The correction:** the solver's output is not a free-standing curve. It is the output of alternating
projection — pins applied, then the gradient limit. A plain filter over `z` violates both:

- It **moves pinned samples.** A bridge deck or a junction elevation slides, silently, and the junction
  resolve loop then re-pins and re-solves against a road that moved. Pins winning is the solver's whole
  documented contract.
- It can **breach the gradient limit** near a pin, where the filter pulls a sample toward a neighbour the
  pin is holding away.

So smoothing is not a post-filter. It is **a filter followed by re-projection**, reusing the solver's own
`_apply_pins` and `_project_grade` rather than new copies of them. Structurally that argues for it living
as a final stage of the solver — `road_align_solve_with_plan` natively, and
`Pasture3DRoadAlignmentSolver.solve_with_plan` in the oracle — rather than in the brush:

```
smooth pass  ->  _apply_pins  ->  _project_grade (to convergence)  ->  _fill_diagnostics
```

`_fill_diagnostics` must run **after** smoothing, or `peak_grade` and `feasible` describe a profile that
is no longer the one being graded.

### 3.2 Why not just raise `w_smooth`

The obvious question, and it deserves an answer here rather than a rediscovery later. `w_smooth` trades
against the **earth** term globally: raising it makes the road stop paying for cut and fill, so it floats
off the ground and imports material everywhere. That is a different road, not a smoother one. The request
is to remove bumps at the elevation the solver already chose — a conditioning pass on the result, not a
reweighting of the objective.

### 3.3 The parameter

The request — "smooths larger bumps the higher it is raised" — is a **scale** knob, not an amplitude one.
A wider kernel removes longer wavelengths; that is the behaviour asked for and it falls out of the kernel
width directly.

```gdscript
## Removes bumps shorter than roughly this along the road, metres. 0 disables smoothing entirely.
@export_range(0.0, 200.0, 0.5, "or_greater", "suffix:m") var smooth_radius: float = 0.0
```

**In METRES, not samples.** `alignment_step` is authorable, so a sample-count parameter would silently
change every road the moment the step changed — the same class of bug as measuring in grid fractions
instead of metres. The kernel half-width is `int(round(smooth_radius / ds))`, and a radius below one
sample is a no-op rather than an error.

**Kernel: three box passes**, not a Gaussian. Three iterated boxes approximate a Gaussian closely enough
that nothing downstream can tell, cost O(n) per pass with a running sum, and — unlike a truncated
Gaussian — have an exactly stated support, which is what makes criterion B below assertable.

Ends are clamped (extend the end sample), not wrapped and not zero-padded: a road is not periodic, and
zero-padding would drag both ends toward zero elevation.

### 3.4 What must not be forgotten

- **`alignment_digest` must include `smooth_radius`.** It currently hashes plan points, `ds`, drape,
  `max_grade`, `design_speed` and pins. A cached alignment that does not know the radius changed is a
  road that does not rebuild when the user drags the slider — the memoisation trap, where a stack copies
  its inputs' bytes and a changed input never says so.
- **Superelevation is unaffected, and this should be asserted rather than assumed.** `plan_curvature`
  works from the PLAN, and banking from curvature, so smoothing `z` cannot change either. If a gate ever
  shows banking moving under smoothing, something is reading `z` that should not be.
- **`smooth_radius = 0` must be bit-identical to today's output**, not merely close. That is the control
  that proves the pass is off rather than approximately off.

### 3.5 Gate — `RoadSmoothGate`

Pure arithmetic, no terrain, no scene — the same property that makes the alignment solver testable.

**Every criterion runs twice**, once native and once under `force_gdscript`, and a seventh compares the
two. A native-only run cannot tell a correct pass from one the oracle never received.

Fixture: a synthetic ground profile carrying two superimposed sinusoids — 0.3 m at 60 m wavelength (the
"small bump") and 2.0 m at 400 m (the "larger bump") — over a 2 km road.

| # | Claim | Control that must fail |
|---|---|---|
| A | `smooth_radius = 0` reproduces the current profile **bit-for-bit**. | Any non-zero radius changes it. |
| B | A radius sized to the small bump attenuates its band by >90% and the long band by <10%. Measure per band, not as a single RMS — an RMS drop is equally consistent with flattening the whole road. | Reverse the two: a radius sized to the long bump must attenuate BOTH. That is the "smooths larger bumps the higher it is raised" claim, and only the pair of measurements proves it. |
| C | Every pin is honoured **exactly** after smoothing. | Remove the `_apply_pins` re-projection and this must fail. |
| D | `peak_grade <= max_grade` after smoothing, on a profile where the pre-smoothing solve was already at the limit. | Remove the `_project_grade` re-projection and this must fail. |
| E | Banking and curvature are bit-identical with and without smoothing. | A guard: its failure means something reads `z` that should not. |
| F | `feasible` and `peak_grade` describe the SMOOTHED profile. | Move `_fill_diagnostics` above the smoothing pass and this must fail. |
| G | Native and forced-GDScript profiles agree to 1e-5 m at a non-zero radius. | Perturb the native kernel width by one sample: the two must diverge. Agreement at radius 0 proves nothing — both are doing nothing — so this must be measured with the pass ON. |

Criterion B is the one worth writing first, because it is the only one that distinguishes "measured
nothing" from "measured well": a smoothing pass that did nothing at all would pass A, C, D, E, F and G.

---

## 4. Suggested order

1. **P9b first.** — **BUILT 2026-09-02.** It was smaller, pure arithmetic, its gate needed no terrain,
   and it changed a surface P9a then draws on.
2. **P9a-0, the junction polygon and the trimming change** (§2.2). It comes before every markings item
   because all of them are drawn on the surface it produces, and because it is the only step that
   changes where the arms END — stop bars, continuations and guides are all positioned relative to that
   boundary. Building markings against the disc first means repositioning every one of them afterwards.
3. **P9a stop bars**, which are nearly free — the data is published and `endpoints()` already exists.
   — **BUILT 2026-09-04.**
4. ~~**P9a arm continuations**~~ — **RETIRED 2026-09-04.** Step 2 did not reposition this item, it
   removed its reason to exist: the ribbon now ends exactly on the boundary, measured at 0.0000 m. See
   §2.3.
5. **P9a crosswalks and give-way triangles** (§5 q3, now in scope — see below). — **BUILT 2026-09-04.**
6. **P9a connector ribbons and guides**, the largest piece and the only one with a geometry question.
   — **BUILT 2026-09-04.** The geometry question resolved itself: the ribbon is sampled off
   `connector.curve`, so continuity with the lanes is a property of the curve rather than of this
   kernel. **This completes P9a, and with P9b it completes this document.**

---

## 5. Open questions for the author

1. **Should connector ribbons be a different material to the apron?** A distinct surface reads better in
   an editor and worse in a shipped scene. Defaulting to the same material and exposing an override on
   `Pasture3DRoadNetwork` is the cheap answer, but it is a decision.
2. **Should `smooth_radius` be inheritable through the `RoadType` / `RoadGroup` / `RoadBrush` chain like
   the other road settings, or per-brush only?** Inheriting is consistent; per-brush is what "this one
   road is bumpy" actually wants. The resolve chain makes either cheap, so this is a taste call.
3. ~~**Crosswalks and give-way triangles**~~ — **RESOLVED 2026-09-04: in scope.** They were deferred on
   the reading that P9a was a minimum viable set. The author's stated expectation is "realistic
   intersection road markings like the rest of the road", and an intersection without a crosswalk or a
   give-way line does not read as one. They are `plan_junction` primitives of the same shape as
   `STOP_BAR` — `CROSSWALK` is a ladder of bars across an arm just outside the stop bar, `GIVE_WAY` is a
   row of triangles at the stop line of any arm whose `effective_control()` is not `SIGNALS` and whose
   priority loses. Both derive from data `Pasture3DRoadStopLine` and `junction.priorities` already
   carry. **Add gate criteria H and I in §2.6 with them.**
4. ~~**Does `corner_radius` belong on `Pasture3DRoadType` or on the junction?**~~ — **RESOLVED
   2026-09-04, see §2.2.3.** On the type, selected at a junction by the highest-priority participant,
   with the group's or network's default as the tie-break and a per-junction override. The ambiguity
   that made this a question — two road types meeting, each with an opinion — is settled by the same
   field that already settles `elevation`, and the tie-break keeps scene order out of the geometry.
