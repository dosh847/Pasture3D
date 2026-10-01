# Road segments override the whole road, and blend into their neighbours

Status: accepted 2026-09-30.

## 1. The problem

A `Pasture3DRoadSegment` is meant to say "from point 5 to point 27 this road is different". It already
resolves through the chain Segment -> Brush -> Group -> Network -> RoadType, but most consumers ask for
the road's value once for the whole road and never pass a distance. So a segment only reaches a few of
them:

| Consumer | Honours a segment today |
|---|---|
| Grader widths (half, shoulder, verge), bridge, jump, walls | yes, per alignment sample, as a hard step |
| Grader crown, crown mode, batters, toe/hinge rounding, bank cap | no, road-level scalars |
| Alignment solver (max_grade, design speed, vertical accel, banking, hairpin, follow_terrain) | no (only the jump mask) |
| Curve widening | no: brush type, in the grader AND per chunk midpoint in the mesher |
| Ribbon mesh width, shoulder, crown | no: one `half_width` for the whole road, so a 6-lane segment grades wide ground under a 2-lane ribbon |
| Ribbon on/off (`surface_mode`) | no: the brush type decides for the whole road |
| Ribbon material, collider surface info, kerb defaults and dimensions, divider, props | no: brush type |
| Terrain paint texture | no: one `surface_layer_id` |
| `suppress_paint` | declared, never read |
| Junction widths, crown, priority, kerb return | no: brush type |

And where a segment does apply, it applies as a step: the width jumps at the boundary.

## 2. The rule

**Every setting a segment carries, directly or through its `road_type`, applies to its stretch of road,
and continuous settings blend into the neighbouring stretch over the segment's `transition_length`.**

"Settings a segment carries" means its own override fields (lane_count, traffic_flow, surface_id,
speed_limit, follow_terrain, kerbs, is_bridge, suppress_paint, allow_airborne_jump, walls) plus EVERY
field of the road type it resolves to.

### 2.1 Precedence inside a segment

A segment that names its own `road_type` takes that type's values over the road modifier's overrides
(`crown_override`, `verge_override`, the batter and rounding overrides). The segment is the more
specific statement: "this stretch is a dirt track" means a dirt track's batters too. A segment without
its own type inherits the road's type, and the modifier's overrides still apply there. Walls keep their
existing order (segment wall, modifier wall, type wall).

### 2.2 Stretches

The segment edges cut the road into STRETCHES, each owned by one LEVEL: the road itself, or the last
segment in the array that covers it (the existing last-wins rule, unchanged). Adjacent stretches with
the same owner merge.

### 2.3 Transitions

Each boundary between two stretches is a TRANSITION centred on the boundary:

* Its length is the `transition_length` of the segment whose edge it is. Where both sides are segments,
  it is the one later in the array, for the same reason the later one wins an overlap.
* It is clamped so it never reaches past the middle of either stretch. Two transitions therefore never
  overlap, and a short segment still reaches its own values at its middle.
* It never runs off either end of the road.
* Across it, a continuous value runs from the left level to the right with a smoothstep weight.
* A discrete value (a bridge, a kerb type, a wall design, the ribbon on or off, the crown mode, the
  texture) switches at the boundary itself: exactly where the segment's range says, as today.

`transition_length` defaults to 10 m. 0 is a hard step.

### 2.4 What is continuous

half width (lanes x lane width + shoulder), shoulder, verge, crown, bank cap (max_superelevation, which
the grader also uses for the crown), cut and fill batter, toe and hinge rounding, curve widening
(factor and max; `curve_widening_enabled` off contributes 0), max_grade (as the solver's per-sample
step), vertical crest and sag curvature limits (from design speed and the accel limits), the banking
design speed and cap, hairpin grade compensation, and follow_terrain, as a 0..1 drape weight.

### 2.5 What is road-level on purpose

* `sharp_point_radius`. It shapes the PLAN, and the plan is what segment ranges are measured along. A
  radius that depended on a range that depended on the radius has no fixed point.
* `type_name`. It is only a label.
* Everything on the chunk host and the network (LOD distances, collision toggle, and so on). These are
  not road settings.

## 3. The ribbon

* Chunks are cut at every stretch boundary, not only at bridge and kerb segments.
* A stretch that resolves to `TERRAIN_DRAPED` builds no ribbon, collider or markings. Props still build.
* A ribbon stretch next to a draped one keeps its ribbon to the boundary, and over the last half of the
  transition the ribbon SINKS: its lift runs from `DEPTH_LIFT` down to `-RIBBON_SINK` at the boundary.
  The ground was graded to the same surface, so the ribbon's end disappears into the terrain instead of
  stopping at a visible edge, and the paint crossfade (section 4) carries the blend on the terrain.
* Width, shoulder and crown are read per ring from the same per-sample arrays the grader uses, so the
  ribbon is exactly as wide as the formation that was graded. That includes curve widening, which the
  mesher used to take once per chunk at its midpoint.
* Material, collider surface info, kerb defaults and dimensions, divider and props come from the
  stretch's own type. Props are cleared and placed per mesh id across every type the road uses.
* The terminus aprons use the level at their end of the road.

## 4. The paint

The grader already knows the arc length `s` of every cell it grades. It reports it as a `surface_s`
mask. Where the road's stretches use more than one texture (or any stretch suppresses paint), the
paint picks each cell's texture from the stretch at `s`. Inside a transition the choice is dithered by
a stable per-cell hash against the transition weight, so two surface textures break up into each other
over the transition instead of meeting at a line. A stretch with `suppress_paint`, or with
`surface_layer_id` -1, paints nothing.

The native stamp takes an optional per-cell texture array. A road with one texture passes none, and its
paint is unchanged.

## 5. Junctions

The junction solver reads a road's half width, shoulder, crown, crown mode, bank cap, priority and kerb
return from the stretch at the junction's arc length, not from the road's own type.

## 6. Caches

* `Pasture3DRoadSegment.signature()` includes `transition_length`.
* `alignment_digest` includes the solver's per-level values and the stretch layout.
* The chunk host digest includes every level's mesher inputs and the stretch layout.

## 7. Criteria (RoadSectionGate)

Each has a control that fails.

* **[W] width follows the segment.** A 6-lane segment on a 2-lane road: the grader's `half` array and
  the ribbon's ring width both reach the 6-lane value inside the segment and the 2-lane value outside
  it. Control: with the segment removed, both stay at 2 lanes.
* **[B] blend.** Across a 10 m transition the width is monotonic, is at the midpoint value at the
  boundary, and is at the end values half a transition either side. Control: `transition_length = 0`
  steps within one sample.
* **[C] clamp.** A 4 m segment with a 10 m transition reaches its own value at its middle, and its two
  transitions do not overlap.
* **[G] grading scalars.** A segment whose type has different crown, batter and rounding grades its
  stretch with them: the native and GDScript graders agree cell for cell. Control: the same fixture with
  the segment's type set equal to the road's matches the unsegmented road.
* **[S] solver.** A segment with a lower `max_grade` holds the solved profile to that grade inside it and
  not outside it. Control: an unsegmented road exceeds the lower grade in the same place.
* **[D] draped ribbon.** A `TERRAIN_DRAPED` segment on a ribbon road: no chunk covers its middle, chunks
  cover the rest, and the last ring before the boundary is below the ground. Control: a
  `RIBBON_PHYSICS` segment leaves the ribbon continuous.
* **[P] paint.** Two stretches with different textures: cells well inside each carry their own texture,
  and cells inside the transition carry both. Control: a `suppress_paint` stretch paints no cell.
* **[J] junction.** A junction inside a 6-lane segment sizes its footprint from the 6-lane width.
* **[K] caches.** Changing a segment's `transition_length` changes the segment signature, the alignment
  digest (when a solver value differs across it) and the chunk digest.
