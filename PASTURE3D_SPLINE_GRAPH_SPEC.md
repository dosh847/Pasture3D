# Pasture3D Spline & Graph Geometry Operations Specification

**Document:** `PASTURE3D_SPLINE_GRAPH_SPEC.md`
**Status:** **S1 + S2 + S3 + S3b BUILT 2026-09-05** (`SplineSourceGate` 6/6, `PathHeightGate` 4/4, `PathCarveGate` 5/5, `PathCarveGpuGate` 4/4 — the last is windowed-only and reports SKIPPED headless; `PathHeightGate` [D] and `PathCarveGate` [E] likewise need a windowed run, and all were verified windowed). S4–S8 specified, unbuilt.
**Target:** Pasture3D Terrain Graph + brush system (Godot 4.7 GDExtension, C++20, GDScript)
**Builds on:** `PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md` (the PATH port, the geometry table, §8.1 Shape
Source, §8.2 rivers) — this document is the general-geometry half of the family that spec's §1 lists and
never built.
**Supersedes on completion:** `PASTURE3D_RIDGE_TROUGH_FLANK_SPEC.md`, whose two-reference drape becomes
one graph node rather than two brush rasterisers (§9).

> Read the status line with suspicion — a spec saying "unbuilt" may be half-built by the time you plan
> from it. Check for the symbols named in each phase before starting; §3 is the audit as of the date
> above.

---

## 1. What this is for

`PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md` §1 lists what a first-class geometry pin makes possible:

> rivers … coastlines and lake shores … cliff lines, fence lines, walls, hedgerows, treelines — anything
> authored as a curve … boundaries and regions … scatter and placement

Every one of those is now unblocked and none of them exists. The PATH port carries a road, and a road is
the only thing that can produce one: `Road Source` names a `Pasture3DRoadBrush`, and `Shape Source` names
a shaping brush's *outline*, which is a by-product of a Mound rather than something anyone draws on
purpose. **There is no way to draw a line and hand it to the graph.**

This document adds three things:

1. **`Pasture3DSpline`** — a scene node whose entire purpose is to be authored as a curve and read by a
   graph. It publishes a PATH and paints nothing.
2. **`Spline Source`** — the graph node that imports it, working the way `Road Source` works.
3. **The operation nodes** — what a graph can *do* with a PATH beyond distance and mask: carve a
   cross-section, read the drawn elevation, drive width from a field, and reshape the line itself.

And then it cashes them in: **Ridge and Trough are rebuilt** as closed-loop brushes that ship with a
`Pasture3DSpline` child and a pre-wired graph, replacing two bespoke C++ rasterisers with one node.

### 1.1 Why the spline is not just "a Path3D"

Because a bare `Path3D` has no gizmo that seats points on the terrain, no click-to-add, no tangent
handles that respect the surface, no surface snap, no labels, no stats, no shared-curve warning, no
placement tool and no undo integration. All of that already exists in `Pasture3DTerrainBrush` and is keyed
on that class (`brush_gizmo.gd:91`, `editor_plugin.gd:221/459/481`). A geometry node that is not a brush
gets none of it and would grow a second copy of all of it.

The counter-precedent is `Pasture3DSimPass`, whose header argues *against* extending the brush base:

> NOT a `Pasture3DTerrainBrush`. It owns no layer, draws no spline, has no footprint and never paints —
> extending the brush base would inherit a layer binding, an Add Spline button and an Add Water button
> that all have to be suppressed again.

That reasoning holds exactly where it was written and inverts here. A Sim Pass **draws no spline**; a
`Pasture3DSpline` draws nothing *but* a spline. Three of its four objections are about painting, and §4.2
suppresses those once, on the base, behind one hook — which a Sim Pass could then have used too.

---

## 2. What other systems do

### 2.1 Hesiod / HighMap — the closest comparable, and the one we can read

Hesiod ships a `Path` wire type and roughly twenty nodes on it. Grouped by what they are *for*:

| Group | Nodes | What it buys |
| :--- | :--- | :--- |
| **Rasterise** | `PathSDF` (distance field, with optional `dx`/`dy` warp inputs), `PathToHeightmap` (stroke or filled) | our `Path Distance` / `Path Mask` |
| **Carve** | `PathDig` (`width`, `decay`, `flattening_radius`, `depth`, `force_downhill`), `dig_river` (`riverbank_talus`, `river_width`, `merging_width`, `depth`, `riverbed_talus`, noise), `flatbed_carve` (`bottom_extent`, `depth`, `falloff_distance`, `outer_slope`, radial profile), `trench` | **nothing of ours** — §7 |
| **Reshape (path→path)** | `PathSmooth`, `PathResample` (ten interpolation methods), `PathDecimate`, `PathFractalize`, `PathMeanderize`, `PathInflate`, `PathShuffle`, `PathBezier`/`BSpline`/`Decasteljau` | **nothing of ours** — §8 |
| **Derive** | `PathFind` (A* over a heightmap), `FindCutPath`, `SelectRivers`, `PathToCloud`/`CloudToPath` | **nothing of ours** — §8.4 |

Two structural facts worth taking, both already recorded in the geometry-ports spec §3 and restated
because this document leans on them:

* **`hmap::Path` is `Cloud` plus ordering, and `Cloud::Point` is `{x, y, v}` — one float of payload per
  point.** That is our `half_widths`, arrived at independently. Confirmation the shape is right.
* **The path is ambient, not flowing.** In their tile loop the arrays flow and the path is simply *there*.
  That is our geometry table.

Two things we deliberately do **not** take:

* **Their widths are scalars.** `dig_path` and `dig_river` both take one `width` for the whole path, with
  variation coming from bank talus and noise. §8.2 of the geometry-ports spec already rejected this: our
  table carries `values` per vertex, a river that widens downstream is the normal case, and a scalar is
  the degenerate case of an array (fill it). §7.4 and §8.3 are where that decision gets spent.
* **Their units are normalised to the tile.** `width` is `0.001..0.1` *of the array width*, so the same
  graph produces a different river at a different resolution. Ours are metres, everywhere, for the reason
  `saleve-measured-in-grid-fractions` records: a grid fraction silently rescales when the margin changes.

### 2.2 The rest of the field, briefly

* **UE5 Landmass** — `BP_Landmass_River` is a spline with per-point **width, depth and velocity**, a
  falloff mode (angle / width), and a curve-driven bank profile. Its per-point payload is the strongest
  argument for per-vertex widths, and its "river cuts, then the landscape blends" ordering is the one our
  §8 wiring already expresses as a wire.
* **World Machine** — the Layout Generator's *Path* device outputs a mask and a distance field only;
  shaping is done by feeding those into Terrace/Clamp. Their split is exactly our `Path Distance` →
  falloff → `Blend`, and it is why `Path Carve` earns its place: everyone who only has the split ends up
  hand-building the same five nodes.
* **Houdini** — `HeightField Project Path` and `HeightField Mask by Feature` do the drape and the mask;
  the carve is a ramp over the projected curve. Their `Project Path` is our `Path Drape` (§8.4).
* **Gaea 2** — spline "Draw" input feeding a `River` node with bank/bed parameters, and `Flow` → river
  extraction. The Flow→spline direction is §8.4's `Path from Flow`.

The consensus across all four: **distance + mask + a cross-section carve + a drape**. Nobody ships only
the first two.

---

## 3. What already exists (audit, 2026-09-05)

Reuse is most of the work. Verified present:

| Need | Already there |
| :--- | :--- |
| PATH as a wire type | `Pasture3DGraphNode.PortType.PATH = 9`; `path_output()` / `reads_paths()` / `set_path_inputs()` |
| The payload | `Pasture3DGraphPath` — `points`, `half_widths`, **`heights`**, `closed`, `nearest()`, `inside()`, `length()`, `half_width_at()`, `height_at()`, `content_digest()` |
| Native geometry | `Pasture3DPathGeom` (`src/pasture_3d_path_query.h`) — CSR bucket index, `nearest`, `nearest_brute`, `inside` |
| The table | `GraphGeomEntry` + `GraphProgram::geom` + `in_g` (`src/pasture_3d_graph_ops.h:122`) |
| Ops | `GRAPH_OP_PATH_QUERY = 57`, `GRAPH_OP_PATH_MASK = 58`, `GRAPH_OP_ROAD_GRADE = 59` |
| GPU | geometry SSBO at binding 4, modes 26/27 |
| Consumers | `Path Distance` (distance/s/t), `Path Mask` (corridor or even-odd interior) |
| Producers | `Road Source`, `Shape Source`, **`Spline Source` (S1)** |
| Authored geometry | **`Pasture3DSpline` (S1)** — a brush that publishes a PATH and paints nothing |
| Host resolution | `Pasture3DGraphSources.resolve(graph, host)` — the *one* place, called from the brush's graph step (`pasture3d_terrain_brush.gd:5026`), the editor preview and the inspector hand-off |
| Change propagation | source node `path` setter → `emit_changed` → `Pasture3DTerrainGraph._on_node_changed` → graph `changed` → `Pasture3DNodeGraph._on_graph_changed` → `_stale` |
| Spline authoring | the whole of `Pasture3DTerrainBrush` — gizmo, point pick/add/remove/smooth, tangents, surface snap, labels, stats, corner rounding, shared-curve warning, placement |
| Loop hosting + modifier stack | `Pasture3DPlow` — closed-loop SDF mask, `_supports_modifiers()`, `Pasture3DNodeGraph` step with feathering and a frozen cache |

**Three gaps, each with a cost:**

1. **`Pasture3DPathGeom` has `px`, `pz`, `width` and no heights.** The GDScript `Pasture3DGraphPath` has
   `heights` and `height_at()`; the C++ struct dropped them because no consumer needed them — `Road Grade`
   reads its elevation from the *alignment*, not from the path's vertices. Both Ridge and Trough default
   `follow_spline_height = true`, so "grade to the drawn line" is the common case and it is the one thing
   the native geometry cannot express. Cost: a `height` vector in the struct, a field on `GraphGeomEntry`,
   an array in the GPU SSBO, and a build/flatten site on each of three paths. **§6.**
2. **Nothing consumes a PATH to shape a surface except `Road Grade`.** It cannot be reused: it needs a
   solved `Pasture3DRoadAlignment`, a crown and two batters, and §8.2 of the geometry-ports spec decided —
   for a stated reason — that rivers get no profile block. **§7.**
3. **`geom` is filled at compile time from host-resolved sources.** A PATH→PATH node produces geometry
   *during* evaluation, which the table cannot see. **§8.**

---

## 4. `Pasture3DSpline` — the node you draw

**Class:** `Pasture3DSpline extends Pasture3DTerrainBrush`
**File:** `project/addons/pasture_3d/connectors/pasture3d_spline.gd`
**Icon:** `res://addons/pasture_3d/icons/brush_spline.svg` (new)

A brush that publishes geometry and paints nothing. It reserves no layer, joins no layer's sibling set,
offers no blend mode and no Add Water, and its `_paint_spline` is empty. Everything else about it — the
gizmo, the point editing, the snap, the tangents, the stats, the placement tool — is inherited unchanged,
which is the entire argument for the base class.

### 4.1 Properties

```gdscript
@export_group("Shape")
## Connect the last point back to the first. A closed spline is a REGION boundary: Path Mask fills its
## interior by even-odd winding, and `inside()` becomes answerable. An open one is a route.
@export var closed: bool = false

@export_group("Width")
## Half-width in metres at every vertex, before `width_along`. This is what makes `t` normalised: t = ±1
## is the spline's own edge whatever the width does along its length.
@export var half_width: float = 5.0
## Optional taper: sampled start (x=0) to end (x=1), multiplying `half_width` per vertex. Null = constant.
## This is Ridge's `width_curve`, moved onto the geometry where it belongs — a width is a property of the
## line, not of whoever happens to be carving it.
@export var width_along: Curve

@export_group("Elevation")
## Publish the control points' own Y as the path's `heights`, so a consumer can grade TO the drawn line
## rather than only measure against it. Off = the path says WHERE and nothing about height, and
## `Path Distance.height` reads NAN.
@export var carry_heights: bool = true
```

`snap_to_surface` defaults **off** (`_default_snap_to_surface() -> false`), matching Ridge and Trough: a
spline authored as a crest or a bed line carries a deliberate vertical shape, and re-seating it on the
surface every bake destroys that. `_min_points()` is 2. `_is_closed()` returns `closed`.

### 4.2 The base hook: `_paints()`

One new virtual on `Pasture3DTerrainBrush`:

```gdscript
## Does this brush write into the terrain? False for a node that exists only to publish geometry.
##
## A brush that answers false takes no tool layer, appears in no layer's sibling set, and paints nothing.
## Declared as a hook rather than as an empty `_paint_spline` override because the layer binding is what
## actually has to be suppressed: an empty paint still reserves a layer named "Splines", still joins the
## sibling repaint of every other tool on it, and still shows a Layer dropdown and a blend mode that
## decide nothing.
func _paints() -> bool:
	return true
```

Sites that consult it, all in `pasture3d_terrain_brush.gd`:

| Site | Change |
| :--- | :--- |
| `_refresh_owner` | return immediately after `update_gizmos()` and the consumer refresh (§4.3); never call `_ensure_layer_for` |
| `_get_property_list` | skip the `Layer` group and `tool_layer` |
| `_get_configuration_warnings` | keep the "add a spline" warning; drop the layer warnings |
| `add_pool` / the `Add Water` button | hidden (a spline is not a thing to fill) |
| `_own_footprints` / `_tools_on_owner` | a non-painting brush is never a sibling |
| `brush_raises()` | irrelevant; never consulted, because it is only asked of painting brushes |

`Pasture3DSimPass`'s objections are answered by this one hook, and a later pass may fold it into that
class too. Not in this document's scope; noted so it is not rediscovered.

### 4.3 The thing most likely to be forgotten: consumer refresh

A spline edit today changes nothing, because nothing bakes. The path only reaches a graph when
`Pasture3DGraphSources.resolve` runs, and that only runs inside a *consumer's* bake.

So `Pasture3DSpline` overrides the refresh to bake its readers instead of itself:

```gdscript
## Re-bake every brush whose graph reads this spline. A spline paints nothing, so its own refresh has
## nothing to do; what changed is an INPUT to somebody else's graph, and only that somebody can act on it.
func _refresh_consumers() -> void
```

Discovery walks `Pasture3DTerrainBrush.BRUSH_GROUP` — the constant, never the string, for the reason
`PASTURE3D_BRUSH_GRAPH_SHORTCUTS_SPEC.md` Phase 0 records — and for each brush walks `modifiers` for a
`Pasture3DNodeGraph`, then that graph's nodes for a `spline_source` whose `spline_key` names this node
**or** whose key is empty and whose host is this spline's parent (§5.2).

Two consequences to design for rather than discover:

* **A frozen graph modifier will not re-solve.** `Pasture3DNodeGraph` defaults to `FROZEN` because a
  graph over a terrain-spanning footprint is expensive. The consumer refresh therefore does not silently
  produce new terrain: it marks the modifier stale and the existing "press Bake Graph" warning appears.
  That is correct, and it is also the first thing that will read as a bug, so it is written here and
  surfaced as a node warning on `Spline Source` (§5.3).
* **A spline with no consumers is not an error.** It is a spline you have not wired yet. The
  configuration warning says so; nothing pushes.

### 4.4 Publishing the path

```gdscript
## This spline as a PATH, in world XZ, with per-vertex half-widths and (optionally) heights.
##
## Deliberately NOT `graph_shape_path`, which is the brush base's "my outline" answer and drops Y and
## widths by design (geometry-ports spec §8.1). A Pasture3DSpline is authored FOR the graph, so it hands
## over everything it knows; a Mound's outline is a by-product, so it hands over only where it is.
func graph_spline_path(p_index: int = 0) -> Pasture3DGraphPath
```

Rules, each with a live alternative that was rejected:

* **World space, from `_baked_world_points`.** Not local. A spline holds local point positions and a
  reparented or moved spline that published them would land at the origin and still look like a perfectly
  plausible curve — the failure `GraphShapeSourceGate` criterion A exists to catch.
* **The ring is left OPEN even when `closed` is true.** `Pasture3DGraphPath.closed` carries the flag and
  the resource repeats `points[0]` itself, in exactly one place. Closing it here would close it twice.
* **`half_widths` is expanded to one value per vertex** — `half_width × width_along(s/length)` — even when
  `width_along` is null and every entry is identical. A per-vertex array is what the table carries and
  what `Path Width` (§7.4) edits; a scalar fast path would be a second representation of one thing.
* **`heights` is empty when `carry_heights` is off**, not zero-filled. `height_at` answers NAN for an
  empty array, and NAN in a HEIGHT grid means "no data" per `PASTURE3D_NODE_VOCABULARY.md` §1. A
  zero-filled array would mean "sea level", which is a plausible-looking wrong answer.
* **Several splines, several paths.** `graph_spline_path(i)` indexes the node's `Path3D` children the way
  `graph_shape_path(i)` does. An index past the end resolves to EMPTY, never clamped, so a deleted spline
  cannot leave a graph quietly pointing at a line nobody chose.

### 4.5 The spline key

`spline_key()` mirrors `shape_key()` and `road_key()`: the node's path **relative to its terrain**,
derived and never stored, so renaming renames the key and a stale key resolves to nothing rather than to
the wrong spline.

---

## 5. `Spline Source` — the import node

**Class:** `Pasture3DGraphNodeSplineSource extends Pasture3DGraphNode`
**File:** `project/addons/pasture_3d/graph/pasture3d_graph_node_spline_source.gd`
**op:** `&"spline_source"` · **role:** GENERATOR · **outputs:** `["path"]` : `[PortType.PATH]`

Structurally identical to `Road Source` and `Shape Source`: a key, an index, an injected
`Pasture3DGraphPath`, an `editor_spline_keys` list stamped by the host with
`notify_property_list_changed()` (without which the dropdown never appears — `property-hints-need-notifying`),
a `_validate_property` that offers `PROPERTY_HINT_ENUM_SUGGESTION` rather than `ENUM`, and a
`native_lower()` that writes zeros because the geometry rides in the table, not in the params.

Everything above is a copy of an existing file with three names changed. The two things that are **not**
copies are below.

### 5.1 The empty key means "my host's own spline", and that is load-bearing

`Road Source` with an empty key falls back to the host road. `Shape Source` deliberately does *not*,
because a brush masking itself by its own outline is a step that can never change anything.

`Spline Source` **does**, and it resolves to **the first `Pasture3DSpline` child of the host brush**.

This is not a convenience. It is the property that makes the Ridge preset (§9) work at all:

> A key is a scene path. A Ridge preset whose graph names `"Ridge/Crest"` would, when duplicated, produce
> a second Ridge whose graph still names the *first* one's spline. Every copy would carve the original's
> line. The preset would be unusable as a preset, which is the only thing it is for.

An empty key is relative to whoever is running the graph, so a duplicate resolves to its own child. A
typed key is absolute, so a spline can be shared deliberately — which is the case the user named: *"the
input spline could be removed from the graph and used by another brush."* Both work; the default is the
one that survives duplication.

### 5.2 Host resolution

`Pasture3DGraphSources` gains `resolve_splines(graph, host)` and calls it from `resolve()`, alongside the
road and shape halves. Same rules as the existing two, for the same reasons, and they are not restated
here except where they differ:

* A key naming no spline **leaves the node's path alone** rather than clearing it. Clearing would make a
  spline mid-rename flatten every terrain reading it for one bake.
* `_assign` compares `content_digest()` and returns early when unchanged, or a graph with a spline in it
  re-solves every downstream erosion on every bake. This has its own gate criterion with a control that
  moving a point *does* bump the revision.
* **`Pasture3DSpline` is excluded from `shape_brushes()`.** A `Pasture3DSpline` offered in the Shape
  Source dropdown would hand over its outline through `graph_shape_path`, which drops the widths and the
  Y it was authored to carry — silently. Two ways to do one thing, one of them worse, which is the rule
  §8.1 of the geometry-ports spec already applied to road brushes.

### 5.3 Warnings

```
"Spline Source has no key and no host spline: it produces nothing."
"Spline Source \"%s\" has not been resolved yet; it produces an empty path."
"Spline Source \"%s\" is CLOSED, so Path Mask fills its interior rather than giving a corridor."
"This graph is FROZEN, so moving the spline will not change the terrain until you press Bake Graph."
```

The last one is the §4.3 surprise, said at the place you are looking when you hit it.

### 5.4 What S1 built differently from §4–§5

Three departures, each recorded rather than quietly absorbed.

1. **No `Spline Source` FROZEN warning.** §5.3 listed one. It cannot live on the node: a graph is a
   Resource and cannot see the `Pasture3DNodeGraph` modifier hosting it, which is the same reason source
   nodes have to be resolved from outside in the first place. It is also redundant —
   `Pasture3DNodeGraph.modifier_warnings()` already says *"is FROZEN and the graph has changed since it
   was baked, so the terrain is showing a stale result"*, on the brush, which is where you are looking.
   The node instead warns about the two things it CAN see: a closed path (Path Mask will fill it), and an
   empty height array (anything grading to this line has nothing to grade to).

2. **The published polyline is decimated to one vertex per terrain cell.** Not in §4.4, and needed:
   `Curve3D` bakes at a fixed 0.2 m interval, so the gate's 20 m line arrived as 181 collinear vertices —
   an index the query builds, walks and caches for nothing. Decimating in `graph_spline_path` rather than
   in each consumer also means the graph and the brushes see the *same* polyline; two decimations of one
   curve disagree in the corners, and that disagreement reads as a solver bug.

3. **`_refresh_consumers()` is not gated on `Engine.is_editor_hint()`.** §4.3 implied it would be. The
   editor-only half is the re-bake, and `_schedule_refresh` already declines to queue one outside the
   editor; the resolution half is plain data. Gating the whole function would have made criterion [D]
   measure nothing and report a pass for it.

Two things the gate caught that the spec had not anticipated, both in the gate rather than the code:
`get_property_list()` lists every GDScript member variable whatever `_get_property_list` does, so testing
for the *name* `_layer_owner` answers a question nobody asked — the real test is the STORAGE usage flag
that decides persistence. And `queue_free()` between criteria leaves the previous fixture in the brush
group that `_refresh_consumers` scans, with both fixtures deriving the key `"River"`; the sibling count
dropped from 3 to 1 when that was fixed, which is how the leak was confirmed real rather than theoretical.

**Deliberately not done in S1:** the palette category is still `"Roads"`, which is already the wrong name
for a family that will carry rivers and cliff lines by S5. Renaming it touches a hardcoded order list in
`Pasture3DGraphNodeRegistry.categories()` *and* a criterion in `GraphPaletteAndConstantsGate` that reads
`cat_map.get("Roads")` — renaming without the gate would leave that criterion measuring an empty list.
Worth doing when S3–S5 land more nodes there, together with the gate update.

---

## 6. Heights in the geometry table

The one piece of native work that is not a new node.

### 6.1 The change

```cpp
struct Pasture3DPathGeom {
    std::vector<float> px, pz;
    std::vector<float> width;
    std::vector<float> height;   // NEW: per-vertex elevation, metres. EMPTY = this path carries none.
    ...
    // Elevation at arc length `p_s`, interpolated between the vertices either side.
    // NaN when `height` is empty — the caller's cue that the path says WHERE and not HOW HIGH.
    double height_at(double p_s) const;
};
```

`build()` gains a `p_heights` parameter. `GraphGeomEntry` needs nothing new — the array lives inside
`geom`. The GPU SSBO at binding 4 gains a parallel float array and the shader gains the same interpolation.

**Empty must stay representable.** A road's `Pasture3DGraphPath.heights` is filled; a hand-authored gate
fixture's is not; a `Pasture3DSpline` with `carry_heights` off deliberately is not. Zero-filling on the way
in would turn all three into "sea level" and the difference would be invisible.

### 6.2 `Path Distance` gains a fourth channel

Rather than a new node. The nearest-segment search is already run per cell and already yields `s`;
`height_at(s)` is one more interpolation off an answer we already have, where a separate node would repeat
the entire query.

```
Path Distance:  distance | s | t | height
                HEIGHT   | HEIGHT | HEIGHT | HEIGHT
```

`output_count()` 3 → 4, `native_out_count()` 3 → 4, and the channel is **appended**, so every existing
graph's wires keep their port indices. `height` reads **NaN** where the path carries no heights and where
the path is empty — not `unreachable_distance`, which is a distance and would read as an elevation of ten
kilometres.

### 6.3 What this does not do

It does not give a path a *solved* elevation. §8.2 of the geometry-ports spec is unchanged and is worth
restating because §7 depends on it:

> A road carries a solved vertical alignment because **a road's height is a design decision**. A river's
> height is a **consequence**: water goes where the ground already sends it.

`heights` here is the drawn Y of the control points — an authoring input, not a solve. A river that wants
its bed to follow the ground reads the *surface*, and §8.4's `Path Drape` is how a drawn line is made to.

### 6.4 What S2 built differently: there is no GPU height

§6.1 asks for a parallel float array in the binding-4 SSBO and the same interpolation in the shader.
**Not built, deliberately.**

The GPU evaluator's plan holds **one buffer per slot**, so it cannot serve channels at all — and rather
than serve channel 0 under every port's name, the guard near the top of `graph_eval_grid_gpu` refuses any
program whose wires read a channel above 0. `height` is channel 3. There is no reachable path from a graph
to a height-aware shader, so a height array in the SSBO would be a fast path nothing can take and no gate
can measure, and per `pre-stack-code-gets-deleted` that is not something this repo keeps.

The cost is already paid: `s` and `t` are channels 1 and 2 and have always taken the graph off the GPU.
`height` adds no new limitation, only a fourth reason for one that exists. The day the GPU evaluator grows
per-slot channels, the SSBO array and the shader interpolation belong in that change, where they can be
measured — not banked ahead of it.

`PathHeightGate` [D] is what replaces the GPU parity criterion: it asserts the **refusal**, so if the guard
is ever weakened without the shader being written, the failure is a red gate rather than a river bed graded
to a distance field.

One further detail worth having written down, because it looks like an oversight in both directions:
**heights are not ring-closed alongside the points.** `path_close_ring` appends the first vertex to a closed
path, so a closed ring is one vertex longer than its height array — and `height_at` clamps to the last
entry for exactly that vertex, which is the first vertex's height, because a closed ring's last point *is*
its first point. Closing both would be a second place that has to agree about it.

---

## 7. The operation nodes

Four families, all four requested. Ordered by what the Ridge/Trough rebuild needs.

### 7.1 `Path Carve` — the one that makes §9 possible

**op:** `&"path_carve"` · **role:** SOLVER · **grid node** · `GRAPH_OP_PATH_CARVE = 60`
**inputs:** `["surface" : HEIGHT, "path" : PATH]`
**outputs:** `["height", "bed", "flank", "cut", "fill"]` : `[HEIGHT, MASK, MASK, MASK, MASK]`

This is Ridge's and Trough's mathematics, written once, in one kernel, as a node. It is the general,
profile-less sibling of `Road Grade`: same shape of job, none of the alignment machinery.

#### Parameters

```gdscript
## Which way the cross-section goes. CREST raises to a ridge line; BED carves to a channel floor.
## The sign is named rather than left to a signed `offset`, because it also decides the sensible default
## blend (MAX for a crest, MIN for a bed) and reads correctly in a warning.
enum CrossSection { CREST, BED }
@export var cross_section: CrossSection = CrossSection.CREST

## Metres above (CREST) or below (BED) the reference. With Follow Path Height on, the path IS the
## reference and this is a bonus offset (default 0).
@export var offset: float = 0.0

## Half-width of the FLAT top or floor, metres. 0 = peaked crest / V-basin.
##
## This is where the third arm of the RIDGE / TROUGH / FLAT_BED choice went. Trough's `flat_bed` bool plus
## `bed_half_width` float is one number with a redundant switch in front of it, and as a width it also
## gives a crest a plateau — a causeway, a levee top, a mesa rim — which the bool could not express.
@export var flat_width: float = 0.0

## How the flank reaches the ground. FIXED_WIDTH spreads over the width; SLOPE_ANGLE descends (or rises)
## at `slope_angle` until it meets the terrain, capped by the width.
enum FlankMode { FIXED_WIDTH, SLOPE_ANGLE }
@export var flank_mode: FlankMode = FlankMode.FIXED_WIDTH
@export_range(1.0, 89.0, 0.5) var slope_angle: float = 30.0

## Where the flank's lateral reach comes from.
##   PATH     — the path's own per-vertex half-widths, scaled by `width_scale`. The §8.2 answer: a river
##              that widens downstream does it here, and Path Width (§7.4) is what sets it.
##   CONSTANT — `width` metres everywhere, ignoring what the path carries.
enum WidthSource { PATH, CONSTANT }
@export var width_source: WidthSource = WidthSource.PATH
@export var width_scale: float = 1.0
@export var width: float = 25.0

## Cross-section shape: flat edge (t=0) = 1 -> flank foot (t=1) = 0. Null = rounded cosine.
@export var profile: Curve

## Reference for the crest/floor: the path's own heights (needs §6), or the terrain plus `offset`.
@export var follow_path_height: bool = true

## How the result composites onto `surface`. MAX for a crest and MIN for a bed are the safe defaults:
## neither can move ground the wrong way.
enum Blend { REPLACE, ADD, MAX, MIN }
@export var blend: Blend = Blend.MAX

## Extra feather beyond the flank foot, metres.
@export var falloff: float = 10.0
```

#### The two-reference drape, stated once

This is the paragraph `PASTURE3D_RIDGE_TROUGH_FLANK_SPEC.md` exists for, and it moves here:

> The crest (or floor) sits at the path — `follow_path_height` on — or at the terrain plus `offset`. The
> flank descends from there **to the actual terrain surface at every point**, either over a fixed width or
> at a fixed slope until it meets the ground. Two references, not one: a fixed-height crest over sloping
> ground with a fixed-height skirt would float at one end and bury itself at the other.

The **ground reference under the crest** is interpolated from the terrain height at the *path's own
vertices*, not sampled per cell — Ridge's `base_below_pts` / `ground_ref`, kept, because a per-cell ground
reference makes the crest wobble with every bump the flank crosses.

#### The channels

`bed` is 1 on the flat top/floor, `flank` is 1 on the descending band, `cut` and `fill` split `height` by
whether it lowered or raised the incoming surface. They exist for the same reason `Road Grade`'s do: to
wire straight into a `Blend` mask so erosion can weather *around* a carve rather than through it.

```
Input ─→ Path Carve ──┬─────────────────→ Blend(MIX).a
                      └─ bed → Invert ──┼─→ Blend.mask
                        Erosion ────────┴─→ Blend.b
```

#### What it is not

* **Not `Road Grade`.** No alignment, no crown, no cut/fill batter pair, no bridge suppression, no
  junction skip. A road's height is designed; a carve's is drawn or drained.
* **Not a river solver.** Bank talus, confluences and riverbed noise (HighMap's `dig_river`) are §8.4 and
  beyond. `Path Carve` puts a defined cross-section in the ground; making it *look* eroded is erosion's
  job, wired after it.

### 7.2 `Path Height`

Not a node. §6.2 — a fourth channel on `Path Distance`. Recorded here so the request is visibly answered
rather than silently dropped.

### 7.3 `Path Width`

**op:** `&"path_width"` · **role:** FILTER · **PATH → PATH**
**inputs:** `["path" : PATH]` (a second `field : HEIGHT` port arrives in §8.4)
**outputs:** `["path" : PATH]`

```gdscript
enum Mode { SET, SCALE }
@export var mode: Mode = Mode.SET
@export var width: float = 5.0
## Multiplier sampled along arc length, start (x=0) to end (x=1).
@export var along: Curve
@export var min_width: float = 0.1
```

Small, and it is the node that keeps widths out of every consumer. Ridge's `width_curve` and Trough's
`width_curve` both taper the *carve*; the same taper on the *path* is read by `Path Carve`, by
`Path Mask`, and by `Path Distance`'s `t` normalisation, all consistently, because there is one width.

### 7.4 The reshape family (`Path Shape`)

All PATH → PATH, all pure functions of the input path and their own scalars, all straight ports of
HighMap's algorithms with our units:

| Node | op | Parameters | For |
| :--- | :--- | :--- | :--- |
| `Path Resample` | `path_resample` | `step` (metres), `method` (LINEAR / CUBIC / CATMULL_ROM / BEZIER), `close` | a 6-point drawn line becomes a few hundred vertices so everything downstream has something to work with |
| `Path Smooth` | `path_smooth` | `window`, `intensity`, `inertia` | takes the hand out of a hand-drawn line |
| `Path Decimate` | `path_decimate` | `target_points` (Visvalingam-Whyatt) | the inverse, for cost |
| `Path Fractalize` | `path_fractalize` | `iterations`, `seed`, `sigma`, `orientation`, `persistence` | midpoint-displacement roughness: a coastline, a cliff line |
| `Path Meanderize` | `path_meanderize` | `ratio`, `noise_ratio`, `seed`, `iterations`, `edge_divisions`, `remove_loops` | the river node. A straight drawn line becomes a meandering one, which is the single biggest difference between a drawn river and a believable one |

**Units.** HighMap's `delta`, `sigma` and `radius` are fractions of the tile. Ours are **metres**, converted
at the boundary. A grid fraction rescales silently when the footprint changes, which is the exact failure
`saleve-measured-in-grid-fractions` records.

**Seeds.** `Fractalize` and `Meanderize` are seeded and must be *stable*: the same seed and the same input
path give the same output path, every bake, on both backends. A reshape whose output moved between bakes
would move the terrain under a frozen graph and read as cache corruption.

### 7.5 The derive family — §8.4

`Path Drape`, `Path Width from field`, `Path from Flow`. Deferred to their own phase because they are the
ones that break the compile-time model. §8.4.

---

### 7.6 What S3 built differently: no ADD blend, and no GPU mode

Two departures from §7.1, both deliberate, both recorded here rather than left to be rediscovered as gaps.

**There is no ADD blend.** §7.1 lists REPLACE / ADD / MAX / MIN by analogy with the brush blends, but the
analogy does not survive contact with the kernel: a brush stamp computes a shape in its own space and ADD
is what puts it onto the ground, whereas Path Carve's cross-section is **already draped onto the incoming
surface** — `carved = ground + diff * p`. ADD would therefore be `ground + (carved - ground)`, byte for
byte REPLACE. Offering both would advertise a difference that cannot exist, and a user who picked the wrong
one would find no fault to report. The three that remain differ genuinely: REPLACE takes the carve, MAX
keeps whichever is higher (a ridge that never digs), MIN whichever is lower (a channel that never dams).

**There is no GPU mode.** `GRAPH_OP_PATH_CARVE` lands in the GPU evaluator's `default:` case beside
`GRAPH_OP_ROAD_GRADE`, so a graph containing a carve drops to the CPU whole. `PathCarveGate` [E] asserts
the **bail**, with a control proving the GPU route was live when it bailed, so a guard weakened without a
shader behind it is a red gate rather than a canyon quietly graded to a distance field.

What blocks it is worth naming precisely, because the obvious guess is wrong. **It is not the geometry
table.** The GPU already has one: binding 4 carries a flattened `Pasture3DPathGeom` — count, closed flag,
px/pz, per-vertex width and cumulative arc length — uploaded once per entry and shared by every dispatch
naming it, with the ring already closed and the width shortcuts expanded so the shader has one case. Path
Distance and Path Mask both run on it today. The three things actually missing are:

1. **Heights are not in that layout.** §6.4 skipped them because `Path Distance.height` is channel 3 and
   unreachable; the carve needs them at channel 0, so this becomes a real gap rather than a moot one. It is
   one more per-vertex stripe beside `width` and `cum`.
2. **The per-vertex ground reference has no GPU form.** The two-reference drape samples the incoming
   surface at each path VERTEX, once, and interpolates between those — sampling per cell scallops the
   crest. On the CPU that is an O(vertices) loop before the grid loop; on the GPU it is a second, tiny
   dispatch of `n_vertices` invocations writing into a buffer the carve dispatch then reads. Small, but it
   is the first time this evaluator would need two dispatches for one op.
3. **The four masks are channels 1-4**, and the plan holds one buffer per slot. This is the same limit
   §6.4 describes and it is not Path Carve's to lift.

(3) is the one that decides the shape of the work: with per-slot channels still unwritten, a GPU carve
could serve `height` and nothing else. That is not worthless — `height` is the port a river or a ridge
actually wires — but it means a graph reading `bed` still takes the CPU, and a gate has to prove which of
the two happened. See §7.7.

What was *not* compromised is native lowering. `blocks_native()` is graph-wide, so a carve that refused to
lower would drag every erosion and noise node beside it onto the GDScript evaluator; [E]'s first half is
what holds that line, and its control is that the lowered program actually moved the ground.

---

### 7.7 S3b — a GPU geometry-aware carve (BUILT)

Requested after S3 landed and originally scheduled after the Ridge/Trough rebuild (S6). **Built
immediately instead**, at the user's direction: a Plow carving through the graph in the editor was
already slow enough to be worth fixing, which settles the question the S6-first reasoning was guessing at.

**One prediction in the plan below was wrong, and the correction is the interesting part.** The
vertex-sample pre-pass was expected to force a second dispatch SIZE through a plan that assumes one. It
does not: the pass is dispatched at the grid's own size and indexed linearly, so vertex `v` is written by
cell `v` and every invocation past the vertex count idles — the same trick `GKM_MINMAX_FINAL` already
uses. What remains is a second dispatch, not a second dispatch size, and the plan needed no new concept
at all. The only guard it costs is a refusal when a path has more vertices than the bake has cells, which
is pathological but would otherwise silently truncate the crest.

**Scope: `height` only.** Per §7.6 (3) the plan holds one buffer per slot, so `bed` / `flank` / `cut` /
`fill` cannot be served and this phase does not pretend to. A graph wiring a mask keeps taking the CPU,
correctly, through the guard that already exists.

Three pieces, in order:

1. **Heights into the binding-4 layout.** A fifth per-vertex stripe after `cum`, filled from
   `Pasture3DPathGeom::height`, with the empty case expanded to a NaN stripe so the shader has one case —
   the same treatment `width`'s two shortcuts already get. Retires §6.4's omission on the terms §6.4 set:
   in the change that can measure it.
2. **A vertex-sample pre-dispatch.** `n_vertices` invocations reading the incoming surface buffer at each
   path vertex, bilinear on the cell-centre convention, writing one float each. This is the evaluator's
   first two-dispatch op, so the plan grows the notion of a dependent scratch buffer — small, but it is
   the structural change of the phase and the reason this is not a two-hour job.
3. **The carve dispatch**, a transcription of `pasture_3d_path_carve.cpp`'s per-cell body, reading the
   profile LUT the way the grader's shader would have. The two-reference rule is what it must not
   paraphrase: `carved = ground + (top - ground_ref) * p`, with `ground` per cell and `ground_ref` from
   (2).

**What was built**, against the three steps above: (1) the height stripe is appended as a fifth
per-vertex stripe, filled with NaN when the path carries none, so every offset Path Distance and Path
Mask were compiled against is unchanged; (2) `GKM_PATH_VERTEX_GROUND` writes one float per vertex,
linearly indexed as described; (3) `GKM_PATH_CARVE` reads the surface at `a`, that array at `b`, the
profile LUT at `c` and the path at `g`, with the five enums packed into `ip2` because five float slots
for five 0-or-1 values would have run the push-constant block out. `tan(slope_angle)` is taken host-side,
inside the CPU kernel's own clamp, so the two sides cannot disagree about where the clamp sits.

**Gate — `PathCarveGpuGate` (4/4, windowed):** [A] GPU vs CPU on the same four cross-sections `PathCarveGate` [A] uses,
control: the GPU route is live (a bare in→out graph returns a field) and the carve MOVED the ground, so a
silent CPU fallback cannot pass as agreement; [B] a graph wiring `bed` still bails — control: the same
graph wiring `height` does not, or [B] is measuring the guard rather than the channel; [C] a path with no
heights and `follow_path_height` on behaves identically on both routes (the NaN stripe), control: the same
path WITH heights differs from it; [D] the vertex-sampled ground reference is what the GPU uses too.
Windowed, reporting NO-SIGNAL headless, as `PathCarveGate` [E] already does.

**[D] needed rewriting once, and the reason is worth keeping.** The intuitive fixture — a big offset over
bumpy ground, checking the crest comes out smooth — measures *nothing*: with `follow_path_height` off,
`diff = (ground_ref + offset) - ground_ref` is the offset whatever the reference is, so it cancels and a
per-cell implementation passes unharmed. It only fails to cancel when the crest is pinned to a DRAWN
height: `crest = ground + (drawn - ground_ref)`, where a per-cell reference cancels to the drawn height
exactly and gives a dead-flat crest, while the per-vertex one lets the terrain's own variation through.
So the discriminator is that the crest **is** rough — carrying 98% of the terrain's roughness as
measured, with 0 of 94 crest cells sitting at the drawn height — which is the opposite of the intuition
the first draft was built on.

---

## 8. The geometry pre-pass — how PATH→PATH nodes lower

### 8.1 The problem, precisely

`compile_graph_program` walks the graph, finds source nodes, and flattens whatever
`Pasture3DGraphPath` each holds into `GraphProgram::geom`. That works because a source node's path is
**already there** — the host injected it before evaluation.

A `Path Smooth` node's path is not. It is a function of its input path and its parameters, and nothing
computes it until something asks.

### 8.2 The answer for pure transforms: resolve the PATH sub-DAG at compile time

`compile_graph_program` gains a first pass:

1. Topologically order **only the PATH edges** — nodes whose `output_port_type()` is PATH and whose
   inputs are PATH ports.
2. Walk that order, calling a new virtual on each:
   ```gdscript
   ## Produce this node's output PATH from its input PATHs. Called during compilation, before any grid
   ## exists. A source node ignores the argument and returns what the host injected.
   func eval_path(_p_inputs: Array) -> Pasture3DGraphPath:
       return path_output()
   ```
3. Flatten the **final** path of every PATH-producing node that some grid op names, into `geom`.

This is a GDScript pass over a few hundred vertices per path, once per compile, against a per-cell query
run `gw × gh` times. It costs nothing measurable and it means a smoothed, meanderised, width-driven river
reaches the native kernel and the GPU as *one flat polyline* — indistinguishable, at the kernel, from a
road. **No new op ids, no shader work, no GPU refusal.** The reshape family is free at the native tier
because it never reaches it.

Fanout stays free: several consumers naming one produced path share one table entry, exactly as several
consumers of one road do (`GraphGeometryLoweringGate` [E]).

### 8.3 Caching

`eval_path` must not re-run on every compile for an unchanged sub-DAG, or a meanderise with eight
iterations runs on every bake of every brush that shares the graph. Cache per node, keyed by
`(input paths' content_digest, this node's revision)` — the same shape as
`Pasture3DGraphNode.solver_cache_key`, and using it rather than a fourth spelling, for the reason that
function's docstring gives.

### 8.4 The nodes that break it, and the rule for them

Three of the requested nodes read a **grid** to produce **geometry**:

| Node | Reads | Produces |
| :--- | :--- | :--- |
| `Path Drape` | the input surface | the path with `heights` sampled from it, optionally forced monotonically downhill (HighMap's `force_downhill`) |
| `Path Width` *(field mode)* | any field — in practice `Erosion.flow` | per-vertex widths remapped from the field at each vertex |
| `Path from Flow` | `Erosion.flow` or `Stream Extraction` | a PATH traced down the steepest accumulation, from a seed or from the field's maxima |

A compile-time pre-pass cannot serve these: the grid they read is produced by the program being compiled.

**Phase S7a — correct, and slow.** These nodes answer `blocks_native() == true`. The whole graph drops to
the GDScript evaluator, where grids and paths are materialised in one topological order and there is no
difficulty at all. This is honest and it is expensive: `graph-gpu-bail-is-graph-wide` — one unsupported op
takes the erosion and the noise beside it down with it.

**Phase S7b — the staged compile.** The graph is cut at each grid-reading geometry node:

```
  compile( everything feeding the node's grid port )  →  evaluate  →
  eval_path( that result )  →  compile( the remainder, with the produced path in its geom table )
```

Two programs instead of one, joined by a buffer. This is real work — the cut, the input-surface hand-off
between stages, and a cache key that spans both — and it is why it is a phase of its own rather than a
paragraph in S5. **S7a ships first and S7b removes its cost**, exactly as P2a shipped native road nodes
that still bailed and P2c removed the bail.

---

## 9. Ridge and Trough, rebuilt

### 9.1 The design, as the user stated it

> The closed ridge loop (modelled after the Plow implementation) is what controls the area. When a spline
> used as an input goes outside the ridge's loop we can use a spline width parameter to update the loop
> spline to fit the change to the input spline within its footprint. We can also have a "Fit to Splines"
> button that shapes the loop to fit all the splines within its footprint. So the Ridge is a closed loop
> brush that comes with a terrain node graph that already has an input spline connected. The brush itself
> is one spline. The input spline could be removed from the graph and used by another brush. It's there to
> speed the setup process so users don't have to make a Plow and an input brush and connect them. They
> have a ready-to-go preset.

Three things follow, and each is a reason this is better than what it replaces:

* **The loop bounds the work.** Today's Ridge derives its footprint from the crest polyline plus reach, so
  every edit re-rasterises a corridor whose extent moves with the line. A closed loop is a stable extent:
  the Plow's dirty-rect machinery (`_spline_dirty_aabb`, the per-extent frozen graph cache keyed on
  `ox,oz,gw,gh`) already exploits that, and a graph modifier that re-solves per drag over a *moving*
  extent cannot hit its cache at all. **This is the performance fix, not a side effect of it.**
* **The spline is not owned.** It is a `Pasture3DSpline` child, and the preset's `Spline Source` finds it
  through the empty-key host fallback (§5.1). Reparent it out and the Ridge stops carving; name it by key
  from another brush's graph and two brushes carve the same line. Neither is a special case.
* **The preset is setup, not semantics.** A Ridge is a Plow whose stack already contains the graph you
  would otherwise have built. Nothing about it is unreachable by hand, which is the property that makes it
  safe to change later.

### 9.2 Class shape

```
Pasture3DTerrainBrush
└── Pasture3DPlow                       (closed loop + modifier stack, unchanged)
    ├── Pasture3DRidge                  (preset: CREST carve, MAX blend)
    └── Pasture3DTrough                 (preset: BED carve, MIN blend, flat floor)
```

`Pasture3DRidge` and `Pasture3DTrough` **keep their class names**, so every scene referencing them keeps
loading. What changes is what they are: `extends Pasture3DPlow`, overriding `_default_layer_name()`,
`_spline_basename()`, `_make_starter_curve()`, `_gizmo_color()`, and adding the preset construction.

Their bodies — `_paint_spline`, the GDScript oracle loops, `_ridge_cross_lut`, `_below_pts` usage — are
**deleted**, along with `Pasture3DData::stamp_ridge_line` and `stamp_trough_line`
(`src/pasture_3d_brush_raster.cpp:1547` and `:1769`) and their bindings
(`src/pasture_3d_data.cpp:2976-2977`). Deleted rather than kept behind a flag, per
`pre-stack-code-gets-deleted`: two implementations of a ridge is the state this work exists to end, and a
kept one is the one that gets fixed instead.

### 9.3 The preset

On `_ready` of a **freshly created** node — never on load, and never when the stack is already populated:

1. Add a `Pasture3DSpline` child named `Crest` (Ridge) / `Bed` (Trough), `carry_heights` on,
   `snap_to_surface` off, with a straight two-point starter curve inside the loop.
2. Add a `Pasture3DNodeGraph` modifier holding a **fresh, scene-local** `Pasture3DTerrainGraph` —
   deliberately not a shared `res://…​.tres`. Two brushes sharing one graph resource would each write
   their own resolved path onto the same `Spline Source` node before evaluating, thrashing its revision
   and defeating the per-node cache for both.
3. Wire it:
   ```
   Input ─────────────→ Path Carve.surface ─→ Output
   Spline Source ─────→ Path Carve.path
   ```
   Ridge: `cross_section = CREST`, `blend = MAX`, `follow_path_height = true`.
   Trough: `cross_section = BED`, `blend = MIN`, `flat_width = 4.0`, `follow_path_height = true`.
4. The graph modifier's `evaluation` starts **LIVE**, not the `Pasture3DNodeGraph` default of FROZEN. A
   carve over one loop is cheap, and a preset that does nothing until you find a Bake button is not a
   preset. `modifier_warnings` already tells you when it is costing too much.

### 9.4 Loop auto-fit

New on `Pasture3DTerrainBrush`, offered only where `_supports_modifiers() and _is_closed()` — the same
gating `modifier_margin` already uses, and already true for a Plow without any new plumbing:
`_is_closed()` defaults to `_min_points() >= 3` (`pasture3d_terrain_brush.gd:5987`) and Plow's `_min_points()`
is 3.

```gdscript
@export_group("Spline Fit")
## Metres of loop kept clear around every input spline. The carve's flank reach plus a margin: a crest
## whose flank is cut off at the loop rim reads as a wall, and the rim is where the feather is.
@export var spline_margin: float = 30.0

## Grow the loop when an input spline moves outside it. Never shrinks — see below.
@export var auto_fit_loop: bool = true

@export_tool_button("Fit to Splines") var _fit_btn = fit_loop_to_splines
```

**Containment test.** Every input spline sample must lie inside the loop by at least `spline_margin`.
Measured with the loop's existing signed distance field — the same `_signed_distance_field` the Plow
already builds for its mask, so containment and masking cannot disagree about where the rim is.

**Auto-grow (per bake, grow only).** For each violating sample, push the two endpoints of the nearest loop
edge outward along the loop's outward normal by the deficit. Preserves the loop's authored shape, is
cheap, and converges. Recorded as part of the bake's undo action so one Ctrl+Z puts both the loop and the
terrain back.

> **It never shrinks, and that is a decision.** A refit that also pulled the loop in would fight the user
> every time they deliberately drew a loop larger than the spline — a Ridge with room for erosion spill,
> a Plow with a graph that reaches past its crest. Growing is the case where *not* acting produces a
> visibly clipped carve; shrinking is the case where acting destroys authored intent. So growing is
> automatic and shrinking is a button.

**Fit to Splines (button, full refit).** Rebuilds the loop as the offset outline of every input spline at
`spline_margin` — a Minkowski sum with a disc, decimated to a workable vertex count. Rules:

* The result is **one ring**. When the splines are far enough apart that the offset yields several, the
  loop is fitted to the ring containing the loop's current centroid and a warning names the splines left
  outside. Bridging them would swallow the ground between, which is not what "fit" means; refusing
  outright would leave a two-spline brush with no button that works.
* Undoable as one action. It replaces authored geometry, and doing that without an undo entry is the
  thing that makes a convenience button feel dangerous.

### 9.5 Migration — a behaviour change, said out loud

This is the risky phase, and pretending otherwise is how it goes wrong silently.

The old brushes' `@export`s are stored on disk. A `_set` shim reads each and writes the preset's
equivalent, following the **stored-property tier** recipe in `PASTURE3D_NODE_VOCABULARY.md` §0:

| Ridge (old) | New home |
| :--- | :--- |
| `crest_height` | `Path Carve.offset` |
| `width` | `Pasture3DSpline.half_width`, with `Path Carve.width_source = PATH` |
| `width_curve` | `Pasture3DSpline.width_along` |
| `flank_mode`, `slope_angle` | `Path Carve.flank_mode` / `slope_angle` |
| `profile` | `Path Carve.profile` |
| `blend_mode` | `Path Carve.blend` |
| `invert` | `cross_section = BED` (an inverted crest *is* a bed) |
| `follow_spline_height` | `Path Carve.follow_path_height` |
| `falloff` | `Path Carve.falloff` |
| `closed` | `Pasture3DSpline.closed` — see below |
| `noise`, `noise_strength` | a `Noise` node wired into the carve's surface — **not** a carve parameter (see below) |
| `smooth_passes` | a `Smooth` node after the carve |

Trough maps the same way, with `depth` → `offset` (BED), `bed_half_width` + `flat_bed` → `flat_width`,
`bank_width` → the spline's `half_width`, and `bank_profile` → `profile`.

**`closed` moves and stops meaning what it meant.** Today it decides whether the *brush's own* spline is a
ring. After the rebuild the brush's own spline is the Plow loop and is *always* a ring; `closed` migrates onto
the child `Pasture3DSpline`, where it decides whether the carved crest is a ring. Both readings are "is this
ridge a loop", so a migrated closed Ridge still produces a closed ridge — but the property that carries the
answer is a different one on a different node, and `Pasture3DRidge._is_closed()` (`pasture3d_ridge.gd:131`)
goes away with the rest of the body.

**And the splines move.** The old brush's own `Path3D` children *were* the crest. After migration they are
the child `Pasture3DSpline`'s, and the brush's own spline is a **new** loop synthesised by running
`fit_loop_to_splines` once. That is the step that can silently produce a wrong-looking brush, so it is
the one the gate measures.

**What will differ.** A migrated Ridge is not bit-identical to the old one and cannot be:

* the old rasteriser had **no loop and therefore no rim feather**; the new one feathers into the terrain
  over the Plow's `falloff_width`, out at the loop, where the old one simply stopped at the flank foot;
* `noise` moves from a per-cell term inside the crest maths to a node before the carve, so the *same*
  noise field lands at a slightly different place in the chain;
* the crest and the flank foot themselves should match to within the grid, because the drape is the same
  drape.

The gate therefore measures **the crest line, the flank reach and monotonicity**, with a stated tolerance,
and does **not** claim bit parity. Saying "within 0.05 m on the crest" and meaning it is worth more than a
tolerance loose enough to pass whatever happens.

---

## 10. Phases

Each phase ships on its own and each has a gate whose controls can fail. Per `bench-gate-practices`, every
criterion has a control that fails, and per `gate-pass-can-mean-nothing-ran`, every gate accounts for
silent criteria — a criterion that threw before asserting must be reported as a failure, not skipped.

| Phase | Scope | Gate |
| :--- | :--- | :--- |
| **S1** ✅ | `Pasture3DSpline` (§4), the `_paints()` hook and its sites, `Spline Source` (§5), `Pasture3DGraphSources.resolve_splines`, consumer refresh, palette entry. **No new maths, no C++.** BUILT — see §5.4 for the three places the build differs from what is written above. | `SplineSourceGate`: [A] the published path is world-placed, carries per-vertex widths and (when `carry_heights`) heights — control: a spline offset from the origin whose local points would look plausible at the origin; [B] the empty key resolves to the host's own child, and a **duplicated** brush resolves to its own — control: a typed key does not follow the duplicate; [C] a non-painting brush reserves no layer and appears in no sibling set — control: the same fixture with `_paints()` true does; [D] moving a point re-bakes the consumer — control: an unrelated brush is not re-baked; [E] re-resolving an unchanged spline does not bump the revision — control: moving a point does; [F] `Pasture3DSpline` is absent from the Shape Source dropdown and present in the Spline Source one. |
| **S2** ✅ | Heights in `Pasture3DPathGeom`, `GraphGeomEntry` flatten, the GPU SSBO array, `Path Distance`'s fourth channel (§6). BUILT — the SSBO array was NOT, see §6.4. | `PathHeightGate`: [A] `height_at` matches `Pasture3DGraphPath.height_at` on a sloped path, CPU / GPU / oracle — control: a flat path is not what is being measured (assert the range is non-zero); [B] a path with no heights reads NaN everywhere, and NaN survives to the output rather than becoming 0 — control: the same fixture with heights reads finite; [C] the appended channel does not move ports 0-2 — control: the pre-change expected values, hard-coded; [D] **replaces [A]'s GPU half**: a graph wired to `height` makes the GPU evaluator bail rather than serving it channel 0 — control: the channel-0 graph must return a field, or there is no RenderingDevice and the criterion reports NO-SIGNAL instead of a pass. |
| **S3** ✅ | `Path Carve` (§7.1): the C++ kernel (`src/pasture_3d_path_carve.cpp`), `Pasture3DUtil.path_carve_grid` + the `_geom` overload, `GRAPH_OP_PATH_CARVE`, CPU lowering, GPU mode, the production node and its `[Dev/GD]` oracle. Follows `PASTURE3D_NODE_ACCELERATION_GUIDE.md` §2 steps 0-6 verbatim. BUILT — with two departures, see §7.4. | `PathCarveGate`: [A] native vs oracle on four cross-sections (peaked crest, flat crest, V bed, flat bed) over sloping ground — control: a zero-offset carve changes nothing, and a control that the fixture is not flat; [B] SLOPE_ANGLE reaches the ground at the stated angle — measured, not asserted from the parameter (`check-derived-values-outside-the-chain`); [C] the five channels are distinct and none is constant; [D] `width_source = PATH` produces a carve that widens where the path widens — control: CONSTANT does not; [E] GPU parity, or an explicit refusal that is *tested to refuse*. |
| **S4** | The geometry pre-pass (§8.2-8.3): `eval_path`, the PATH-sub-DAG topological order in `compile_graph_program`, the cache. Plus `Path Width` (§7.3) as its first customer. | `PathPrePassGate`: [A] a `Spline Source → Path Width → Path Carve` chain lowers **natively** and matches the GDScript evaluator — control: the same graph with the pre-pass disabled falls to GDScript, proving the route was actually taken (`graph-gpu-bail-is-graph-wide`: only a direct native call proves it); [B] fanout is one table entry for two consumers of one produced path; [C] `eval_path` is not re-run when nothing changed — count the calls — control: editing the width does re-run it. |
| **S5** | The reshape family (§7.4): five PATH→PATH nodes, metres not fractions, stable seeds. | `PathShapeGate`: [A] each node changes the path — control: at zero strength each is the identity, byte for byte; [B] the same seed twice gives the same path, and a different seed a different one; [C] arc length after `Path Resample` at 1 m step is within a cell of the input's; [D] `Meanderize` with `remove_loops` produces a non-self-intersecting path — control: without it, on a fixture chosen to loop, it does not. |
| **S6** | **Ridge and Trough rebuilt** (§9): reparent onto `Pasture3DPlow`, the preset, loop auto-fit + Fit to Splines, the `_set` migration shim, deletion of `stamp_ridge_line` / `stamp_trough_line` and the old bodies. | `SplineBrushPresetGate`: [A] a fresh Ridge bakes a raised crest along its child spline without any wiring — control: with the Spline Source unwired it bakes nothing, not a wall; [B] auto-fit grows the loop when the spline leaves it and **never shrinks** — control: a spline pulled well inside leaves the loop alone; [C] `Fit to Splines` is one undo action that restores both loop and terrain; [D] a migrated legacy Ridge's crest line is within 0.05 m of the old rasteriser's and its flank reach within one cell — controls: the fixture is not flat, and the *unmigrated* parameters produce a measurably different surface; [E] a duplicated Ridge carves its own spline, not the original's; [F] the deleted kernels are gone — `ClassDB` no longer exposes `stamp_ridge_line`; [G] **Add Water on a rebuilt Trough still builds a `Pasture3DStream`, not a `Pasture3DPool`** (§12.2) — control: Add Water on a plain Plow still builds a Pool, so the test is measuring the override and not a blanket change. |
| **S3b** ✅ | **A GPU geometry-aware carve, `height` only** (§7.7): heights into the binding-4 layout, a vertex-sample pre-dispatch, the carve shader. BUILT — brought forward to directly after S3 at the user's request, the Plow carve being slow in the editor. The four masks stay CPU — the one-buffer-per-slot limit is not this phase's to lift. | `PathCarveGpuGate`: [A] GPU vs CPU on `PathCarveGate` [A]'s four cross-sections — control: the GPU route is live AND the carve moved the ground, so a silent CPU fallback cannot pass as agreement; [B] a graph wiring `bed` still bails — control: the same graph wiring `height` does not; [C] a heightless path with `follow_path_height` on matches across routes — control: the same path WITH heights differs; [D] the vertex-sampled ground reference is used on the GPU too — measured as the crest carrying the terrain's roughness, NOT as its smoothness; see §7.7 for why the intuitive fixture measures nothing. |
| **S7a** | Grid-reading geometry (§8.4): `Path Drape` (+ force-downhill), `Path Width` field mode, `Path from Flow`. Correct on the GDScript evaluator; `blocks_native()` true. | `PathDeriveGate`: [A] a draped path's heights equal the surface sampled at its vertices — control: an undraped path does not; [B] force-downhill produces a monotonically non-increasing height sequence — control: without it, on the same uphill fixture, it does not; [C] width from `Erosion.flow` widens downstream — control: a constant field does not; [D] each of the three takes the graph off the native path, *and is checked to* — a bail nobody verifies is a bail that quietly stopped happening. |
| **S7b** | The staged compile (§8.4): cut the program at each grid-reading geometry node, evaluate, produce the path, compile the remainder. Removes S7a's graph-wide bail. | `PathStagedCompileGate`: [A] the S7a fixtures now lower natively and match their own GDScript results to the erosion gates' thresholds — control: the S7a bail path, still reachable, gives the same answer more slowly; [B] a two-stage graph's cache invalidates when *either* stage's inputs change — control: changing nothing re-serves without re-solving. |

| **S8** | **Write the Lake & River spec** (§12) — a document, not a build: the Pond overhaul as a preset over the water-accumulation nodes, and what happens to `Pasture3DStream` once a Trough's own spline is a loop. | No measurement gate: the deliverable is a spec with its own phases and gates. What S8 must *close* is listed in §12.3, and the one thing it cannot defer is §12.2, which S6 breaks. |

**Critical path to the user's stated goal is S1 → S2 → S3 → S4 → S6.** S3b sits after S6 by request: it
is a performance phase, and S6 is what makes the carve hot enough for it to be worth measuring.

S5 and S7 are independent of the
rebuild and can land either side of it. S8 is written after S6 has been built, not
before: the Pond overhaul's whole argument is that the Ridge/Trough preset pattern generalises, and that is
a claim about something that exists rather than a prediction about something that does not.

---

## 11. Decisions

Each of these had a live alternative. Recorded so they are argued once.

### 11.1 `Pasture3DSpline` extends the brush base — §4.1
Rejected: a `Node3D` with its own gizmo, following `Pasture3DSimPass`. That precedent's three objections
are all about painting; one hook (`_paints()`) answers them, and it answers them for the Sim Pass too.

### 11.2 The empty key resolves to the host's own child spline — §5.1
Rejected: requiring a key always, like `Shape Source`. A key is an absolute scene path, so a duplicated
preset would carve the original's line. The fallback is what makes a preset duplicable, which is the only
thing a preset is for.

### 11.3 `height` is a channel on `Path Distance`, not a `Path Height` node — §6.2
Rejected: a separate node. The nearest-segment search is already run and already yields `s`; a second node
would repeat the whole query to add one interpolation. Appended at port 3 so existing wires do not move.

### 11.4 One `Path Carve` with `cross_section` + `flat_width`, not RIDGE/TROUGH/FLAT_BED — §7.1
The three-way choice is honoured as one node and one kernel. Its third arm is folded into a **width**
rather than an enum value, because Trough's `flat_bed` bool plus `bed_half_width` float is one number with
a redundant switch in front of it, and as a width it also gives a crest a plateau the bool could not
express. `cross_section` survives as an enum rather than as a signed `offset` because it also picks the
safe default blend and reads correctly in a warning.

### 11.5 Width lives on the path, not on the carve — §7.3
Rejected: `Path Carve.width_curve`, mirroring today's brushes. A width on the path is read consistently by
the carve, by `Path Mask`, and by `Path Distance`'s `t` normalisation; a width on the carve is read by one
of them and the other two silently disagree with it. This is also what §8.2 of the geometry-ports spec
decided when it chose per-vertex widths over HighMap's scalar.

### 11.6 Pure PATH transforms resolve at compile time; grid-reading ones get a staged compile — §8
Rejected for the pure ones: a PATH operand in the SSA program. There is nothing for it to do — a
meanderised river is a polyline, and by the time it reaches the kernel it is indistinguishable from a road.
Rejected for the grid-reading ones: `blocks_native()` forever. The bail is graph-wide and takes the
erosion beside it down; S7a ships it and S7b removes it, the same shape as P2a → P2c.

### 11.7 Auto-fit grows and never shrinks; shrinking is a button — §9.4
Rejected: symmetric refit on every bake. Growing is the case where not acting produces a visibly clipped
carve. Shrinking is the case where acting destroys a deliberately oversized loop. The two are not
symmetric and should not share a trigger.

### 11.8 Ridge and Trough are rebuilt in place, and the old kernels are deleted — §9.2
Rejected: new classes plus a converter, keeping the old ones. Two implementations of a ridge is the state
this work exists to end, and the kept one is the one that gets fixed instead
(`pre-stack-code-gets-deleted`). The cost is that migration is a behaviour change rather than a refactor,
which §9.5 states rather than hides.

### 11.9 The preset's graph is scene-local, not a shared `.tres` — §9.3
Rejected: one shipped graph resource per preset kind. Two brushes sharing one graph would each write their
own resolved path onto the same `Spline Source` before evaluating, thrashing its revision and defeating
the per-node cache for both. A shared *template* that is instanced per brush is the same thing done safely.

---

## 12. S8 — the Lake & River spec

A phase whose deliverable is a document. It is here because the user has settled the question §13 used to
ask: **`Pasture3DPond` becomes a preset, over the nodes around water accumulation**, the same way Ridge and
Trough become presets over `Path Carve`. What that costs is not a paragraph, and it should not be guessed
at from inside a spline spec.

### 12.1 The two sides that have to meet

Water in Pasture3D is currently two systems that were built years apart and have never been introduced.

**Derived from terrain, in the graph** — `depression_filling`, `flooding_uniform_level`, `lake_flooding`,
`stream_extraction`, `hydraulic_stream_log`, `water_mask`, and `Erosion`'s `flow` channel. These *find*
water: `Lake Flooding` locates closed basins, floods each to its spillway, and publishes `height`,
`water_depth` and `shoreline`. It can already spawn a `Pasture3DPond` into the scene from the contour it
computed.

**Authored by hand, in the scene** — `Pasture3DPond` (a Mound with `invert` and MIN blend, plus Add
Water), `Pasture3DPool`, `Pasture3DStream`, `Pasture3DWaterBody`. These *declare* water. `Pasture3DPond`'s
`water_offset` is measured from the loop's lowest rim point, deliberately, so that "the brush dial and the
pool dial cannot disagree" — there is no conversion anywhere.

The direction was flagged by the user on 2026-08-30, in the same breath as approving the deletion of the
last pre-modifier-stack Plow code: *"Since we now have nodes to generate WaterBodies from terrain data we
are going to need to refactor the water brushes in the near future."* So the shape is known — the graph
derives the water and the brush stops being the thing that defines it — and the pre-graph authoring
properties are **deleted rather than shimmed** (`pre-stack-code-gets-deleted`).

What is *not* known is the interesting part, and §12.3 is the list.

### 12.2 The thing S6 breaks, which S8 cannot defer

`add_pool_now()` decides lake-versus-river from **the curve, not the brush class**
(`pasture3d_terrain_brush.gd:3341-3345`):

> The CURVE decides which kind of water this is, not the brush class: closed fills as a lake, open becomes
> a river ribbon (§7.3). A Mound whose loop the user opened is a river, and a Trough they closed is a moat,
> without either of them saying so anywhere else.

After S6, **a Trough's own spline is always a closed loop**. So Add Water on a rebuilt Trough builds a
`Pasture3DPool` — a moat — where today it builds a `Pasture3DStream`. And the bed line it should have
followed now lives on a child `Pasture3DSpline`, which `_get_splines()` deliberately does not collect,
because collecting it is exactly what would make a Plow treat its input spline as one of its own loops.

That is a regression S6 introduces, in a relationship `pasture3d_stream.gd`'s header describes as the
normal way a river gets made: *"Normally created by pressing Add Water on a Pasture3DTrough."* Three ways
out, and **S6 must pick one and pin it with a gate criterion** rather than leaving it for S8:

* **(a) Add Water on a rebuilt brush sources its child `Pasture3DSpline`, not its loop.** Recommended. It
  preserves the documented relationship, and the child spline is precisely what `Pasture3DStream` already
  wants: the Stream takes its level from the *banks* it measures either side of the line, treating the
  spline as the bed floor, which is what a Trough's spline has always been. One override of the spline
  source `add_pool_now()` iterates.
* **(b) Suppress Add Water on the rebuilt brushes** and route river creation through S8 entirely. Honest,
  and it leaves a hole for however long S8 takes.
* **(c) Do nothing**, and a Trough's Add Water makes a moat. This is what happens if nobody decides, which
  is the reason it is written down as an option rather than left as an outcome.

### 12.3 What the Lake & River spec has to close

1. **Where a lake's surface level comes from.** Authored (`water_offset`, rim-relative) or solved (`Lake
   Flooding`'s spillway)? Both exist and neither can read the other. Today the solve can *create* the
   authored thing — `Spawn Pasture3DPond in Scene` — and the authored thing cannot read the solve back, so
   editing the terrain under a spawned pond silently desynchronises the two. That one-way arrow is the
   clearest statement of the problem.
2. **Whether a Pond preset carves, fills, or both.** Today's Pond does both, in one node. The S6 pattern
   splits exactly that: the carve is a graph node over a loop, the fill is a water body. Which suggests
   `Pasture3DPond` becomes a Plow-derived preset whose graph carves the basin and whose Add Water fills it
   — but a basin that is *found* by `Lake Flooding` rather than carved by the preset is a different node
   again, and the spec should say whether those are one thing or two.
3. **What replaces `water_offset`.** Its whole justification is that it shares a frame with the pool's
   `fill_offset` so they cannot disagree. A solved level is in world Y, which is a different frame, and
   re-deriving a rim-relative offset from it re-introduces the conversion the current design exists to
   avoid.
4. **What a river is, after S7a.** Trough-plus-Stream today. Afterwards there are three routes to the same
   river — `Path Carve` in BED mode over an authored `Pasture3DSpline`, `Stream Extraction` from a flow
   field, and `Path from Flow` producing the spline itself — and §8.1's "two ways to do one thing, one of
   them worse" rule applies with three.
5. **Which pre-graph properties are deleted.** Per the rule, not shimmed. Naming them in advance is what
   keeps the migration from becoming a negotiation once it is underway.
6. **The gate family's headless problem, which is load-bearing here.** Most `Water*` / `WaterBodies*`
   gates await `RenderingServer.frame_post_draw` unconditionally, so they never complete without a display
   server — they stop inside criterion A having printed only a heading, which reads as a hang and passes as
   nothing. `WaterBodiesPhase4Gate` and `WaterBodiesPhase6Gate` already carry the one-line fix (wait on
   `process_frame` when there is no renderer); Phases 0/1/2/3/5/7 and the shore probes do not. **A water
   overhaul that ships before that fix cannot be verified in CI at all**, which makes it the first item in
   S8's own phase list rather than a footnote in it. (Phase 6 stays excluded for a different reason: it
   carries millisecond criteria, and benchmarks need the user's go-ahead.)

### 12.4 What S8 inherits from this document

* **The preset mechanism** — §9.3's fresh scene-local graph, §5.1's empty-key host fallback, and §11.9's
  reason a shared `.tres` cannot be used. A Pond preset needs all three and should not re-derive them.
* **Loop auto-fit** — §9.4 lands on `Pasture3DTerrainBrush` gated on `_supports_modifiers() and
  _is_closed()`, so a Plow-derived Pond gets it for free, and a lake whose inlet stream wanders outside its
  loop grows to contain it.
* **`Path Carve` in BED mode with `flat_width`** — a lake bed with a flat floor is the same kernel as a
  river with a flat bed, which is the same kernel as a Trough. That is already the argument for one node
  (§11.4); a Pond is its fourth customer.

### 12.5 Dependencies

The Pond half needs **S1** (a spline to author) and **S3** (`Path Carve` BED) plus the flooding nodes that
already exist. The river half additionally wants **S7a**'s `Path from Flow`. So S8 can be *written* any
time after S6 is built, and its own phases will straddle S7.


## 13. Open

1. **Confluences.** Still deferred, still recorded: `in_g` names one entry, and the cheapest extension for
   several is a `group` id on table entries plus an op that reads every entry in its group
   (geometry-ports spec §8.2). `Path from Flow` (S7a) is the node most likely to want it first, because a
   drainage network is a tree, not a line.
2. **CLOUD.** Reserved at `GraphGeomEntry.kind = 1` and unread. Scatter and placement want it, and
   `Path to Cloud` / `Cloud to Path` are the natural bridge. Out of scope here.
3. **~~Does `Pasture3DPond` become a preset too?~~ Answered: yes.** It becomes a preset over the water-
   accumulation nodes, and the Lake & River spec that covers it is **S8** (§12). What remains open is inside
   that spec rather than here — §12.3 is the list, and §12.2 is the part S6 forces a decision on first.
4. **`Path Find`.** Hesiod's A* over a heightmap, producing a route that follows the terrain's grain. It is
   the natural partner to the road system's own router (`Pasture3DRoadRoute`) and probably belongs there
   rather than here.
