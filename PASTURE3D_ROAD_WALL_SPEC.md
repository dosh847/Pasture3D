# Pasture3D Road Wall Spec

Status: built 2026-09-29 (W0–W6). Supersedes the `cut_wall_height` / `fill_wall_height` floats on
`Pasture3DRoadType` and the matching `Pasture3DNodeRoad` overrides, which are deleted rather than shimmed.

## 1. Why

The first retaining wall was a height CAP on the batter. A batter that climbed more than
`cut_wall_height` stopped, the raw hillside was left standing past that point, and a mesh was hung on
the step between them. Three faults follow from that shape:

1. **It had no size.** The only number was the height at which the wall starts, and that number is also
   where the wall stands. The wall's own height is then whatever the hillside happens to be at that
   run, so along a road it goes up and down with every bump in the ground. That is the "messy" look.
2. **It stood in the wrong place.** A retaining wall on a mountain road stands at the ROAD, holding the
   hill back from the carriageway. The cap put it part way up the batter, with a ramp of earth in
   front of it.
3. **It could not be reused.** Two floats on a type are not a wall design. The same stone wall on a
   lane and on a track meant copying numbers between types, and a segment could not ask for a wall at
   all.

## 2. The resource

`Pasture3DRoadWall` (`roads/pasture3d_road_wall.gd`) is one wall design, used for either kind. A cut
wall holds the hillside back above the road; a fill wall holds the road up above the valley.

| Group | Field | Meaning |
|---|---|---|
| | `enabled` | false makes this resource mean "no wall", so an override can switch a type's wall off |
| Placement | `placement` | `ROAD_SIDE` (default): the wall stands at the edge of formation. `BATTER_TOP`: the old cap behaviour, kept for a wall part way up a slope |
| | `trigger_height` | a wall stands only where the plain batter would climb or fall more than this, metres |
| | `offset` | metres from the edge of formation to the wall's inner face (a ditch in front of a cut wall) |
| Size | `max_height` | the tallest the wall is built. Past it, the batter continues above a cut wall or below a fill wall |
| | `thickness` | metres through the wall. The terrain step sits at `offset + thickness` |
| | `landscape_offset` | cut walls only, default 0.25: the terrain step is set back this far behind the wall, so the one-cell ramp the heightfield draws at the step starts behind the face instead of poking through it. The coping covers the gap |
| | `beyond_batter` | slope of the batter above a cut wall or below a fill wall, rise/run. 0 uses the type's batter |
| | `embed_depth` | metres the face is sunk below the ground in front of it (mesh only) |
| | `lean` | face batter, run/rise: 0.1 leans the face back 10 cm per metre (mesh only) |
| Top | `top_mode` | `FOLLOW_ROAD`: one height per run, the tallest it needs. `STEPPED`: level blocks. `FOLLOW_GROUND`: tracks the need, smoothed |
| | `step_length`, `step_height` | STEPPED block length along the road and height quantum |
| | `top_smoothing` | FOLLOW_GROUND window along the road, metres |
| Runs | `min_length` | a run of wall shorter than this is not built |
| | `gap_bridge` | a gap in a run shorter than this is walled over |
| | `end_treatment` | `TAPER`: the wall ramps down into the plain batter over `end_taper_length`. `SQUARE`: full height to the end |
| Finish | `coping_height`, `coping_overhang` | a cap course on top (mesh only) |
| | `material`, `uv_scale_m` | material and metres per texture repeat (mesh only) |
| | `collision`, `collision_layer` | build a StaticBody3D for the wall (mesh only) |

`terrain_signature()` lists only the fields that move the ground. The mesh-only fields change
`changed`, but not the stamp key, so editing a material rebuilds the mesh and never re-rasterises a
road.

## 3. Where a wall is chosen

- `Pasture3DRoadType.cut_wall` / `fill_wall`: the type's walls. `wall_material` moves into the resource.
- `Pasture3DNodeRoad.cut_wall_override` / `fill_wall_override`: null inherits. A resource with
  `enabled = false` switches the type's wall off on this road.
- `Pasture3DRoadSegment.cut_wall` / `fill_wall`: null inherits. The most specific source wins, so the
  per-sample order is: segment, then modifier, then the type (the segment's own type where it sets one).

`grading_profile` resolves them per alignment sample into `walls` (the unique resources) and
`cut_wall_idx` / `fill_wall_idx` (per sample index into `walls`, -1 = none).

## 4. The wall plan

The terrain and the mesh read ONE record per sample and side, so the mesh cannot drift from the ground.
It is computed in GDScript after the alignment solve, on both bake routes, and is stored on the
alignment as `wall_plan: PackedFloat32Array`.

The record has stride `WALL_STRIDE = 7`. Sample i, side k (0 = the left, side -1; 1 = the right, +1)
lives at `(i * 2 + k) * 7`:

`[mode, kind, W, alpha, o, x_s, beyond]`

- `mode`: 0 none, 1 ROAD_SIDE, 2 BATTER_TOP.
- `kind`: +1 cut, -1 fill.
- `W`: the wall height.
- `alpha`: 0 to 1, the end taper.
- `o`: the face offset.
- `x_s`: the terrain step, `o + thickness`, plus `landscape_offset` on a cut wall (`Pasture3DRoadWall.step_offset`).
- `beyond`: the slope past the wall.

Building it:

1. **Classify.** The kind is set by the ground one step past the edge: above `z_edge` is cut.
2. **March.** Step outward along the plain batter (hinge included) until it meets the ground. The
   height gained there is `h_c`, the catch height. The march is batched: one native height query per
   lateral step for every sample and side at once.
3. **Need.** A wall stands only where `h_c > trigger_height`. That test decides whether a wall is built,
   not its height. A ROAD_SIDE wall retains the ground at its own back face, so its height comes from a
   second batched query at `x_s`: `need = min(max_height, kind * (ground(x_s) - z_edge))`. A wall that
   would hold back 5 cm or less is not built.
   - Sizing it by `h_c` was the first build, and it was wrong. On a 1:2 hillside it stood 1.7 m proud of
     the ground behind it.
   - A BATTER_TOP wall's need is `trigger_height`, the cap.
   - Samples that are suppressed (bridge) or skipped (junction) are inactive.
4. **Runs.** A run is contiguous active samples of one side, kind and resource. Gaps shorter than
   `gap_bridge` that contain no bridge or junction are filled in by interpolating the need. Then runs
   shorter than `min_length` are dropped.
5. **Top.** FOLLOW_ROAD takes the maximum over the run. STEPPED takes the block maximum, rounded up to
   `step_height`. FOLLOW_GROUND takes the moving average over `top_smoothing`. All are clamped to
   `max_height`.
6. **Ends.** TAPER uses `alpha = smoothstep(min(i - start, end - i) * ds / end_taper_length)`. SQUARE is 1.

Ground source: the bake's own grid where the point lies inside it (the GD step route, so a wall sees the
erosion above it), otherwise the layers below this one. The native stamp route reads the layers below
throughout, which is the same ground it grades.

A clipped bake recomputes the whole plan from a grid that covers only the clip, and the layers below
elsewhere. Outside the clip that can differ from a full bake's plan by what the modifiers above the road
did there. The terrain outside the clip is not rewritten, so only the mesh can disagree, and only until
the next full bake. This is accepted.

## 5. The walled grade

`Pasture3DRoadGrader.walled_height` (GD) and `road_wall_height` (native) are line for line the same. At
a cell `x` past the edge, with the record interpolated between the two bracketing samples (linearly when
both have the same mode and kind, otherwise the nearest record):

- **mode 0:** `batter_height` (the plain batter, which no longer takes wall arguments).
- **mode 2 (BATTER_TOP):** the old rule. A batter line more than `W` from the edge leaves the ground
  alone; otherwise the plain batter.
- **mode 1, cut:** on ground at or below `z_edge` the plain batter. Otherwise:
  - `L_wall` is `z_edge` for `x < x_s`, then `z_edge + W + beyond * (x - x_s)`.
  - `L = lerp(L_plain, L_wall, alpha)`.
  - `h = smooth-min(ground, L)`, with toe width `min(toe, max(x - alpha * x_s, 0))` and slope
    `lerp(cut_batter, beyond, alpha)`.
- **mode 1, fill:** mirrored. `L_wall = z_edge - W - beyond * (x - x_s)` past the step, and a smooth-max.

The corridor reach grows to `edge_d + x_s + rise / beyond + verge + toe` wherever a bracketing record has
a wall.

The graph path carries the plan on its alignment (`alignment.wall_plan`) in place of the two floats, so Road
Grade in a graph grades the same walls. Junction earthwork uses the plain batter, because a junction
footprint has no wall plan.

## 6. The mesh

`Pasture3DRoadChunkHost._rebuild_walls` reads the stored plan and the same profile functions:

- **Cut, ROAD_SIDE:**
  - A face at `o` (leaning back by `lean`) runs from `L(o) - embed` up to the top.
  - The top is the terrain step height `lerp(L_plain(x_s), z_edge + W, alpha)`. For FOLLOW_GROUND it is
    lowered to the ground behind the wall.
  - A cap runs from `o - coping_overhang` to `x_s + band`, raised by `coping_height`.
  - A back face drops from the cap to the ground behind wherever that ground is lower.
- **Fill, ROAD_SIDE:**
  - The outer face at `x_s` runs from the top (`lerp(L_plain(x_s), z_edge, alpha)`, plus coping) down to
    the baked ground at `x_s + band`, minus `embed`.
  - A cap runs from `o` to `x_s + coping_overhang`.
- **BATTER_TOP:** the original step-hiding strip.
- **Every strip:**
  - End caps at both ends of each run.
  - UVs in metres over `uv_scale_m`.
  - One surface per material.
  - Collision when any wall asks for it.

`band = 1.5 * vertex_spacing` covers the one-cell ramp the heightfield draws at the step.

## 7. Gates

`RoadWallGate`: one criterion per control, each with a control arm that has to fail.

| Id | Control | Asserted |
|---|---|---|
| A | placement | ROAD_SIDE step within one cell of `edge + x_s`; BATTER_TOP step at the batter run |
| B | trigger_height | no wall where the need is below the trigger; a wall where it is above |
| C | max_height | the step is at most `max_height`, and the batter above it continues at `beyond` |
| D | offset / thickness | the step moves by the change in `offset + thickness` |
| E | top_mode | FOLLOW_ROAD one W per run; STEPPED multiples of `step_height`; FOLLOW_GROUND varies |
| F | min_length / gap_bridge | a short run is dropped; a short gap is filled |
| G | end_treatment | TAPER alpha ramps to 0 at the ends; SQUARE is 1 |
| H | GD / native parity | `grade_reference` equals `grade` with a wall plan, within 1e-4 m |
| I | fill wall | mirrored step below the edge |
| J | mesh | faces present, at `o` for a cut wall, and the terrain signature ignores the material |
| K | override resolution | a segment wall beats the modifier, which beats the type; `enabled = false` removes it |
| L | landscape_offset | a cut wall's terrain step moves out by it while the mesh face stays at `o`; a fill wall ignores it |

`RoadEarthworksShapeGate` criteria W and M move here and are deleted from that gate.
