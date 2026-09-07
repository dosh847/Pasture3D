# Pasture3D Graph Visualization & Output Specification

**Document:** `PASTURE3D_GRAPH_VISUALIZATION_SPEC.md`
**Status:** **V1, V2 and V3 BUILT (2026-09-06/07); V4–V7b specified, unbuilt.** V1 ships as `GraphPreviewReprGate` at 114 checks — criteria [A], [A2], [B], [C], [D], [E], [F], [G], [H], [I], each red-watched. One deviation from the table below: [A] is worded inverted relative to §5.2's prose ("renders identically" where the prose requires the two mask fields to render DIFFERENTLY against a shared absolute scale, which is the point of an absolute scale); it is built to the prose, and the gate asserts both halves. One thing found and not fixed, out of V1's scope: `compile_graph_program_multi` ignores `blocks_native()`, so a FROZEN solver previews through a live re-solve. V2 ships as `GraphPreviewChannelGate` at 25 checks, both halves red-watched. One deviation from §8: it names `compile_graph_program_multi` as the allocation half, but that function already emits `out_count` from `native_out_count()` unconditionally — what is demand-driven is the EVALUATOR's liveness pass in `graph_eval_grid_core`. Both halves are in `pasture_3d_graph_ops.cpp` as §8 says, just not in the function it names. The tap return gains a third key, `reserved`, so a gate can assert on the reservation itself rather than on a field being non-zero. V3 ships as `GraphPathOverlayGate` at 34 checks — criteria [A]–[F], built as a plain `RefCounted` (`graph_path_overlay.gd`) so the gate measures the vertex arrays rather than that the gizmo was called. [A]'s control is the criterion and fires: substituting `derive_without_grid` for `derived_path()` fails both halves. `_returned`/`derived_path()` were lifted to `Pasture3DGraphNode` and `_resolved_path_of` made a recording wrapper — `eval_path` cannot record a PATH SOURCE (short-circuited) nor a memo HIT. One documented behaviour turned out not to be load-bearing: the `has_heights` guard on the drop lines is redundant, because a heightless path is drawn AT `get_height` and `DROP_EPSILON` already suppresses the degenerate drops; [C3] pins it with a flat-height control. Ten open questions answered 2026-09-06 — eight in §14.1/§14.1b, plus §14.2 items 1 (measured) and 3 (settled). Two remain open (§14.2 items 2 and 4). The substrate V1 and V2 extend — editor-owned
multi-tap previews, `graph_eval_grid_taps`, `GraphPreviewTapGate` — is BUILT and passing. V3's dependency
(`derived_path()` on the derive family) is BUILT. V7's consumers (`Pasture3DRoadRuntime`,
`Pasture3DWaterBody`) are BUILT and in use; V7a is the arrow back to them, not the consumers. V7b's seam
(`_still_surface_y` as a virtual, overridden by `Pasture3DStream`) is BUILT — see §9.4.
**Target:** Pasture3D Terrain Graph editor + brush/bake system (Godot 4.7 GDExtension, C++20, GDScript)
**Builds on:** `PASTURE3D_SPLINE_GRAPH_SPEC.md` (the PATH sideband, the geometry pre-pass §8, the derive
family §7.5, and §12.3's named-but-unclosed producer→consumer gap), `PASTURE3D_NODE_ACCELERATION_GUIDE.md`
(the native-lowering contract every node here must answer to),
`PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md` (the `[Dev/GD]` rule).
**Supersedes on completion:** nothing. Every phase here extends a system that already ships.

> Read the status line with suspicion — a spec saying "unbuilt" may be half-built by the time you plan
> from it. Check for the symbols named in each phase before starting; §3 is the audit as of the date above.

### Reading map

Every *working* section below opens with a **Read first** block naming what to review before working on it
(§13 and §14 carry none — they are a scope boundary and a question log, not work). This is the same
information by phase, for planning:

| Guide | Needed by | Why |
| :--- | :--- | :--- |
| `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` | **All** | The graph as built, not as planned. §8 (the editor) is this document's starting position; §9 (sockets, `SLOT_SPINS`, never restate a range) constrains V1 and V6; §10 says which existing gate owns which claim; **§11 lists three bugs that are earlier instances of §4's defects** |
| `PASTURE3D_NODE_ACCELERATION_GUIDE.md` | V2, V5, V6, V7b | §2 Step 0 (is this node allowed to exist), §3.2 (lowering safety), §3.4 + §3.8 (gate discipline every gate here is written against), §5 (the memory pool V2 changes) |
| `PASTURE3D_LAYERS_GUIDE.md` | **V5**, V6 | §10.7 already built the control/colour write path V5 calls; §8.1 is the four-step contract every sink follows; §4.3 + §5.1 are why the mask is coverage, not opacity |
| `src/pasture_3d_editor.cpp` + `src/pasture_3d_data.cpp` | **V5** | Not a guide, but §9.1a's prerequisite lives here: `:108` / `:1043` gate stroke routing on `TYPE_HEIGHT`, and `_ensure_typed_base` / `composite_region` are why a control overlay changes what the region map *means*. Read before touching a sink |
| `PASTURE3D_SPLINE_GRAPH_SPEC.md` | **V3**, V7a | §7.5 + §8 define what "the path the graph resolved" means, without which §6.3's trap reads as pedantry; §12.3 is the open item V7a closes |
| `PASTURE3D_WATER_GUIDE.md` | **V7b**, V7a | §6 (querying water from code) and §5 (`Pasture3DBuoy`) are the live contract V7b must not break, and §9.4 is why the seam already exists |
| `PASTURE3D_ROAD_CONNECTOR_GUIDE.md` | V5, V7a | The `#holes` control layer is the working precedent for a graph-owned typed layer |
| `PASTURE3D_RELIEF_MATERIALS_GUIDE.md` | V5 | §6–§7 are what actually *reads* base/overlay/blend — the consumer side of the control-word review |
| `PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md` | V5, V6, V7a | The `[Dev/GD]` rule, which sinks are an odd case of: no kernel to be a twin of |
| `PASTURE3D_PR_WORKFLOW_GUIDE.md` | **All** | Adding a gate, CI, and **the demo-data problem** — a gate touching `data_directory` can rewrite the demo terrain, and a clean `git status` afterwards proves nothing |
| `PASTURE3D_BRUSH_GIZMO_*_SPEC.md` (3) | V3 | The overlay is a contribution to an existing `EditorNode3DGizmoPlugin`, not a new one |

---

## 1. What this is for

> **Read first:** `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §1–§2 (the pieces, the data model, ports and types).
> It is the document that outlives the specs — the spec is a build plan and finishes, the guide describes
> the thing that was built. `PASTURE3D_NODE_VOCABULARY.md` for what things are called.

Two needs that share a word and share nothing else.

**(A) Debug visualization.** Seeing what is actually flowing through the graph mid-chain — masks, flow
accumulation, curvature, slope, distance fields, the width and height profile along a PATH, curve remaps.
This is for the author, in the editor, while authoring. It is throwaway. Its only job is to answer a
question the author has *right now* and then get out of the way.

**(B) Final output.** Artifacts a game consumes — heightmaps, control/splat maps, normal maps, flow and
wetness masks, material index maps, and the runtime data structures a road network or a water surface
publishes. This is **data leaving the graph**, not a thumbnail. It is durable, it is versioned, and when
it is wrong the game is wrong.

These are conflated constantly in the field — Hesiod calls its `Preview` node's category "Debug" and its
`ExportHeightmap` node lives in the same palette three rows down — and conflating them produces exactly
one bug, over and over: **something rendered for looking at gets used for computing.** A preview is
normalised, downsampled, tone-mapped and clamped, and every one of those is correct for a thumbnail and
catastrophic for a heightmap. This document keeps them apart by construction: (A) never writes anything,
and (B) never renders anything.

### 1.1 The one-sentence version of each half

- **(A)** is three surfaces — an inline thumbnail, a viewport overlay, and a pinnable inspector — because
  "which wire is which", "is this geometry right" and "what is this number" are three different questions
  and no single surface answers all three (§5).
- **(B)** is three owners — the bake system, a file sink, and the runtime consumers that already exist —
  because a control-map write, a PNG on disk, and a road network for car AI have nothing in common except
  the word "output" (§9).

---

## 2. What other systems do

> **Read first:** nothing of ours — this section is the research and its sources are named inline. If you
> want to re-verify it, the primary files are `Hesiod-main/Hesiod/src/gui/widgets/data_preview.cpp`,
> `.../viewers/`, `.../node_widgets/export_node_widget.cpp`, the ten
> `.../model/nodes/nodes_function/export_*.cpp`, and `Hesiod-main/docs/guides/export-formats.md`.

Grounded in source on disk where possible. `Hesiod-main/` is vendored in this repo and was read directly;
everything else is from knowledge of the tools and is flagged as such.

### 2.1 Hesiod / HighMap — read from source

Four questions were asked of it. The answers are specific and two of them are worth taking.

**Q1. What is the taxonomy of preview representations, and which live inline vs in a dedicated viewer?**

`Hesiod/src/gui/widgets/data_preview.cpp` declares five and ships four:

```cpp
enum PreviewType { GRAYSCALE, MAGMA, TERRAIN, SLOPE_ELEVATION_HEATMAP, HISTOGRAM };
```

`SLOPE_ELEVATION_HEATMAP` is commented out of `preview_type_map` — shipped disabled. The inline thumbnail
is a right-click menu with two sections: **Preview type** (the representation) and **Data** (which output
port is being shown). That two-axis choice — *what am I looking at* × *how is it drawn* — is the correct
decomposition and we should copy it.

`update_preview()` dispatches on `typeid(...).name()` of the port's data, so the representation is chosen
from the C++ type, not from the port's declared meaning. `hmap::Array` (a scalar grid) gets the ramp;
`hmap::Cloud` and `hmap::Path` get bespoke renderers; `hmap::HeightMapRGBA` is blitted. Path is drawn as
`path.remap_values(0.1f, 1.f); path.to_array(array, bbox);` — **geometry rasterised into the thumbnail's
own grid**, not the grid the node occupies. This matters to us (§6).

The dedicated viewer (`viewers/viewer_3d.cpp`) is a different taxonomy entirely: six **roles**
`{elevation, water_depth, color, normal_map, points, path}`, each with an icon and an eye toggle, each
routed to a port by the user. The inline thumbnail asks "draw this port"; the viewer asks "which port
plays this role in a scene". They are not the same question and Hesiod is right to split them.

**Q2. Is `Preview` a node or a port-attached viewer — why, and what does it cost?**

Both, and the node is a decoy. `Hesiod/src/model/nodes/nodes_function/preview.cpp` declares seven IN ports
(elevation, water depth, scalar, texture, normal map, cloud, path) and **`compute_preview_node` has an
empty body**. It computes nothing. Its entire function is to be a *bundle* — a single selectable object
that gathers seven scattered outputs so the viewer can follow one selection instead of seven.
`docs/examples/Preview.hsd` is one generator wired to one Preview node and nothing else.

The cost is elsewhere and it is large. `node_widgets/node_widget.cpp` constructs
`this->data_preview = new DataPreview(model, this);` in `setup_layout` **for every node, unconditionally**,
subscribed to `pre_update_event` / `post_update_event`. Every node in the graph renders a thumbnail on
every evaluation whether anyone is looking at it or not. Our design already beats this: `preview_on` is
per-node and opt-in, the render is a separate tap pass, and `evaluate()` never touches it
(`graph_editor.gd:878` says so in a comment, and it is true). **Do not regress this.**

**Q3. How do export nodes avoid running on every parameter tweak?**

A boolean and a button. Every one of the ten `model/nodes/nodes_function/export_*.cpp` files opens its
`compute_` with `if (!auto_export) return;`, and `node_widgets/export_node_widget.cpp` supplies the button:

```cpp
bool auto_export = m->val<bool>("auto_export");
m->set_value<bool>("auto_export", true);
m->compute();
m->set_value<bool>("auto_export", auto_export);
```

It flips the flag, computes, flips it back. Batch export (`model/graph/override_export_nodes_settings.cpp`)
is a **JSON file rewrite before the run** — it forces `auto_export = true` on every node whose label
contains "Export", rewrites `fname` to `<export_path>/<label>_<id>_<basename>`, and optionally forces
`octaves = resolution / 128`. And `node_widget_factory.cpp` dispatches on
`node_type.starts_with("Export")` — a **naming convention**, not a declared capability.

This is three separate string-matching hacks stacked on one mutable flag, and every one of them is a
symptom of the same missing idea: the graph has no way to say "this node is a sink". We have that idea
already and don't need any of it (§9.2).

**Q4. What is the data-type → representation mapping, and how does a node declare what its output means?**

`viewers/wild_guess_view_param.cpp` is the honest name for it. It reads **port names and category
substrings as an API** — `cat.find("Selector")`, an exclusion list of names `{"water_depth", "mask"}` — to
guess which port should drive which viewer role. `render_helpers.cpp::generate_selector_image` then renders
anything it decided was a selector in magenta.

So: a node does not declare what its output means. The GUI infers it from a string. That is the failure
mode to avoid, and the fix is already in our tree — `output_port_types()` at
`pasture3d_graph_node.gd:335` returns a typed array. **The type is the declaration. Never read a name.**

### 2.2 The one thing Hesiod gets wrong, and we inherited independently

**Every preview is per-array min/max normalised, silently, including the ones that look absolute.**

`data_preview.cpp`:

```cpp
auto build_colored_array = [&](hmap::Array &array, hmap::Cmap cmap, bool normalize = true)
{
  const float minv = array.min();
  const float maxv = array.max();
  return hmap::colorize(array, minv, maxv, cmap, normalize).to_img_8bit();
};
```

And it is not just the ramps. `external/HighMap/HighMap/src/colorize/colorize.cpp`:

```cpp
Texture colorize_grayscale(const Array &array) { Texture color1 = Texture(array); color1.remap(); return color1; }
```

Grayscale remaps. `colorize_histogram` bins over the array's own min/max **and draws no axis**. So a
histogram — the one representation whose entire purpose is to show you the distribution *in a range* —
carries no range. Hesiod's only escape is `node_widgets/debug_node_widget.cpp`, which prints `addr`, `min`
and `max` as monospace text on a debug node nobody puts in a graph.

The consequence is the one that costs an afternoon: **a mask that is uniformly 0.3 renders full-range
white**, and a slider that scales a mask from 0.3 to 0.6 changes the picture *not at all*, because both
renders are remapped to their own extremes. The author concludes the parameter is broken. It is not.

We have the identical bug, arrived at independently. `src/pasture_3d_util.cpp:1911`, `hillshade_image_grid`:

```cpp
float h_range = std::max(max_h - min_h, 0.001f);
// ... norm_h = clamp((val - min_h) / h_range, 0, 1)
```

`p_is_mask` only switches the RGB tint — amber vs grey-green — it does **not** switch the normalisation.
This is `calibration-constants-must-be-stored-not-printed` in picture form: the divisor is part of the
image's meaning, and an image that does not carry its divisor is not an interface. §5.2 is the fix.

### 2.3 The rest of the field, briefly

From knowledge, not source. What matters is what appears in *all* of them — repetition across tools with
different owners, different eras and different taste is the signal that something is load-bearing.

| Affordance | WM | Gaea | World Creator | Houdini HF | Substance D | Blender GN | Verdict |
| :--- | :-: | :-: | :-: | :-: | :-: | :-: | :--- |
| Inline per-node thumbnail | ✅ | ✅ | ✅ | — | ✅ | — | Universal in **node-graph** tools; absent where the graph is a side panel to a 3D view |
| Solo / "view this node" flag | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | **Universal, no exceptions** |
| Both, as separate gestures | ✅ | ✅ | ✅ | n/a | ✅ | n/a | Universal where both exist — they are never merged |
| 2D inspector with probe + histogram | ✅ | ✅ | ✅ | ✅ | ✅ | ~ | **Universal.** The numeric surface always exists somewhere |
| 3D preview is a **proxy**, not the shipped terrain | ✅ | ✅ | ✅ | ~ | n/a | n/a | Universal. We are the deliberate outlier (§12.11) |
| Explicit build/export step separate from preview | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | **Universal** |
| Preview resolution ≠ build resolution | ✅ | ✅ | ✅ | ✅ | ✅ | n/a | Universal, and always visible in the UI |
| Named output/sink node set | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Universal |
| Any visualization of a curve's **width envelope** | — | — | — | ~ | — | ~ | **Essentially no prior art** (§6) |

Four conclusions:

1. **Thumbnail and solo are two questions, and every mature tool ships both.** We already do
   (`graph_editor.gd:782` `★`/`Out`, `graph_editor.gd:790` `👁`). Nothing to do here — but nothing to
   merge, either.
2. **The quantitative surface is universal and is the one we are missing.** Every tool has somewhere to
   read an actual number — a probe, a histogram, a min/max readout. This is exactly the thing that cannot
   fit in a 128 px thumbnail, which is why it is always a separate panel and never an improvement to the
   thumbnail. §7.
3. **Preview resolution is always shown when it differs from build resolution.** Every tool that
   downsamples says so on screen. This settles the shape of the opt-in downscale (§5.4).
4. **Nobody visualizes a path's width envelope.** Houdini can be made to, with effort; Blender's geometry
   nodes can, with a spline-to-mesh detour. There is no affordance to copy. §6 is designed from the data,
   not from prior art, and it should expect to be wrong once.

---

## 3. What already exists (audit, 2026-09-06)

> **Read first:** `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §8 (the editor — and its first bullet is this
> document's whole starting position, "previews are owned by the editor, not the node") and §3 (the three
> evaluators and which one runs). `PASTURE3D_LAYERS_GUIDE.md` §10.7 before believing anything in the audit's
> control-map rows — the layer stack already writes control and colour, which §9.1 depends on.

**Do not rebuild any of this.** §4 is the list of what is actually wrong with it, and every item is local.

| Symbol | Where | State |
| :--- | :--- | :--- |
| `preview_on` | `pasture3d_graph_node.gd:65` | `@export`, no emitting setter — deliberate, and load-bearing (§12.6) |
| Preview toggle `👁` | `graph_editor.gd:790` | Per-node opt-in, one undo action, instant show/hide |
| Solo output `★`/`Out` | `graph_editor.gd:782` | Separate gesture, separate meaning |
| `PREVIEW_SIZE` / debounce | `graph_editor.gd:64,66` | 128 px, 0.12 s |
| `_schedule_preview_refresh` | `graph_editor.gd:1633` | Debounced, coalescing |
| `_refresh_previews` | `graph_editor.gd:1650` | One `compile_graph_program_multi(roots)`, one `WorkerThreadPool` dispatch |
| `_preview_worker` | `graph_editor.gd:1698` | Off-thread `graph_eval_grid_taps` + `hillshade_image_grid` per tap |
| `_apply_preview_textures` | `graph_editor.gd:1716` | Token-guarded, reuses `ImageTexture` in place |
| `graph_eval_grid_taps` | `pasture_3d_graph_ops.cpp:1526`, bound `pasture_3d_util.cpp:1299` | Protects tap slots from the arena recycler; one field per requested tap |
| `hillshade_image_grid` | `pasture_3d_util.cpp:1911` | The only representation there is |
| `GraphPreviewTapGate` | `project/bench/GraphPreviewTapGate.gd` | 3 criteria, controls incl. an all-zero "measured nothing" check |
| `output_port_types()` | `pasture3d_graph_node.gd:335` | The type declaration V1 reads |
| `PortType` | `pasture3d_graph_node.gd:211` | HEIGHT, MASK, VECTOR, CURVE, FLOAT, INT, COLOR, BOOL, TERRAIN_BUS, PATH |
| `derived_path()` | `pasture3d_graph_node_path_derive.gd:178` | Returns what the node last **handed the graph**. V3 depends on it |
| `eval_path_count` / `capture_count` | same file | The pair that separates "the grid never arrived" from "it arrived and did nothing" |
| `brush_gizmo.gd` | `_redraw` at :94 | `add_lines`, `Sprites._dot_sprite`, subgizmos. V3's drawing primitives, already written |
| `Pasture3DRoadRuntime` | `roads/pasture3d_road_runtime.gd` | runs + links + `locate()`. **B3, built** |
| `Pasture3DWaterBody` | `connectors/pasture3d_water_body.gd` | `get_water_height`, Gerstner inverse, buoyancy. **B3, built** |
| `Pasture3DData::export_image` | `src/pasture_3d_data.cpp:2600` | r16/raw/exr/png/jpg/webp/res/tres; height/control/colour; sliced or per-region |
| `bake_all_brushes()` | `connectors/pasture3d_sim_manager.gd:1525` | Registry walk, per **layer owner**, one undo, cancellable, reports. V6's model |
| Control word layout | `src/pasture_3d_util.h:654–697` | base(5)@27, overlay(5)@22, blend(8)@14, uv_rot(4)@10, uv_scale(3)@7, **free(4)@3–6**, hole@2, nav@1, auto@0 |

**A preview system exists and is editor-owned.** Nothing below proposes replacing it. §4 lists six
defects; V1 fixes (i), (ii), (iii), (v) and (vi), and V2 fixes (iv).

---

## 4. The six defects

> **Read first:** `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §11 "Things that have actually gone wrong" — items
> **2** (`@export` with no setter), **4** (`native_out_count()` serving zeros that look like a real answer)
> and **9** (an unwired port binds the zero buffer) are three earlier instances of two of the six defects
> below. Then §3 (the evaluators) and §6 (solvers and the freeze), because defects (iv) and (v) are both
> about what happens when the native route is not taken.

Each is stated as a symptom an author would report, because that is how they will arrive.

### 4.1 (i) "Every node looks like terrain"

There is one representation. `hillshade_image_grid`'s `p_is_mask` switches the tint and nothing else, so a
mask, a distance field, a curvature field and a heightmap are all rendered as lit relief. Curvature is
signed and gets a sequential ramp, so zero — the meaningful value — is wherever the data happens to put it.
A distance field in metres gets hillshaded as though 40 m of distance were 40 m of altitude.

### 4.2 (ii) "The slider does nothing"

Per-grid min/max normalisation, unlabelled (§2.2). Two specific failures:

- **A mask is wrong to normalise at all.** A MASK's range is 0..1 by definition; that is what makes it a
  mask. Rescaling a uniform-0.3 mask to full white is not a display choice, it is a false statement.
- **A self-rescaling view hides the parameter you are adjusting.** This is the authoring failure and it is
  worse than the first, because it is invisible. Drag a gain slider on a HEIGHT field and the image does
  not move — both renders normalised to their own extremes — so the author concludes the wire is dead.

### 4.3 (iii) "The Path Drape thumbnail is black" — and black has **four** causes

A PATH-producing node still occupies a grid slot filled with zeros
(`pasture3d_graph_node_path_derive.gd:107`, `eval_cell` returns `0.0`). So its thumbnail is black. But so
is a genuinely-flat field. And so is a dead tap, because `graph_eval_grid_taps` writes a zero field for a
slot that is out of range or has no live buffer (`pasture_3d_graph_ops.cpp:1526`, and the comment above it
says so plainly). And so is a tap the worker silently dropped —
`_preview_worker` has `if field.size() != PREVIEW_SIZE * PREVIEW_SIZE: continue`, which leaves the previous
texture in place.

Four causes, one pixel value, no way to tell them apart. The author's next move is to debug the wrong one.

### 4.4 (iv) The solver channels are unreachable

Erosion publishes `flow`, `ero`, `dep`, `wet` on channels 1..3, and there is no way to preview any of them.
`graph_eval_grid_taps` takes `PackedInt32Array p_tap_slots` — a slot, with channel 0 implied. The comment
at `pasture_3d_graph_ops.cpp:513` states the assumption outright: *a tap and the graph output are both
channel 0 by construction.*

**The trap:** widening the tap API alone is not enough and is actively dangerous. `want_aux` returns
`nullptr` for an unallocated channel and the producing op then **skips writing it**, so a tap on an
unallocated channel returns a field of zeros — which for `flow` renders as a plausible, calm, entirely
fictional map of still water. The compiler's aux allocation must be widened in the same phase, and the
gate must have a control that fails when either half is missing (§11, V2 [B]).

**This exact bug has already been met once.** `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §11 item 4:
*"`native_out_count()` returning `output_count()` — a channel the kernel never writes is served as zeros,
which looks like a real answer."* Same mechanism, same disguise, one layer down. Item 9 of the same list —
*"assuming an unwired port means something other than zeros"* — is the third instance. Zeros are this
system's universal impostor, and §5.5's `unserved` report is the general fix.

### 4.5 (v) A non-lowering graph shows stale thumbnails forever, silently

```gdscript
var compiled: Dictionary = graph.compile_graph_program_multi(roots)
if compiled.is_empty():
    return # non-native graph (e.g. a solver mask wire); leave the last thumbnails in place this tick
```

`graph_editor.gd:1664`. "This tick" is optimistic — nothing changes the condition, so it is every tick
until the wire is removed. Four more silent returns sit around it (no extension method at :1654, no roots
at :1661, no tap slots at :1677).

This is the worst of the six, because the graph editor is the one place in the plugin that *already knows*
the graph did not lower and *can name the op* — `native_supported()` is right there
(`pasture3d_terrain_graph.gd:1816`) — and it says nothing. Per `op-ids-omission-drops-graph-to-gdscript`,
a single missing entry in `graph_op_ids()` puts the whole graph on the GDScript evaluator, and the symptom
the author sees today is thumbnails that stopped updating.

---

### 4.6 (vi) "The preview is showing the wrong brush's terrain"

The thumbnail evaluates over the host brush's real footprint — `_get_preview_input_data`
(`graph_editor.gd:431`) asks `_find_host_modifier()` for `last_input_surface`, `last_rect` and the grid
size. Which brush that is comes from `_find_host_brush()` (`graph_editor.gd:264`), and it has four tiers:
an explicitly bound `host_brush`, then a brush derived from `host_modifier`, then a scan of the editor
selection, then **a scan of the whole `BRUSH_GROUP` for any brush whose modifier stack contains this
graph**.

That last tier returns the *first* match `get_nodes_in_group` yields. **Two brushes can host the same
`Pasture3DTerrainGraph` resource** — that is the point of a graph being a resource — and when they do, the
preview's input surface comes from whichever brush the scene tree happens to name first, not from the one
whose graph you opened. Every thumbnail in the panel is then a correct evaluation of the wrong terrain, and
nothing on screen says so.

`edit_graph(p_graph, p_mod, p_brush)` (`graph_editor.gd:88`) already accepts a brush and binds it. The
defect is that the binding is optional, so the fallback is reachable at all.

---

## 5. (A1) The thumbnail: representation and range

> **Read first:** `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §8 (the editor) and **§9 (sockets and inline
> parameters)** — §9 carries two rules V1 will otherwise break. *"Port colour is `PORT_COLORS[type % size]`,
> so a new `PortType` without a colour silently reuses another type's — add both together"* (V1 adds no
> `PortType`, and must not start), and **"never restate a range in the editor"** — 37 of 41 widget/property
> range pairs had drifted, 16 destructively. The range chip in §5.2 is a *readout of the data*, not a
> restatement of a property, and the distinction is the whole reason that rule exists.
> Also §2 "Ports and types" (the type declaration §5.2's Rule 1 reads) and §7 (invalidation and caching),
> because the range lock must not participate in either.

### 5.1 The form-factor decision, argued

Four candidates were live.

| Option | What it answers well | What it cannot do | Cost |
| :--- | :--- | :--- | :--- |
| Inline thumbnails only | "which wire is which", at a glance, for many nodes at once | Any question with a number in it. 128 px has no room for an axis, a probe readout or a legend | Already paid |
| Dedicated 2D inspector only | Everything quantitative | Scanning a chain. You cannot compare six nodes by selecting them one at a time | New dock, selection plumbing |
| Solo-to-3D only | "does the terrain look right" | Anything mid-chain. A mask soloed to the terrain is a grey plane | Already paid (the `★` flag) |
| All three | — | — | Sum of the above |

**Picked: keep the two we have, fix them (V1, V2), and add the two that are missing (V3 viewport overlay,
V4 inspector) as separate later phases.**

The argument is §2.3's second and fourth conclusions. Thumbnail-and-solo is universal across every tool and
we already ship both; the *quantitative* surface is equally universal and we ship none of it; and the
geometry surface (V3) has no prior art but is the thing the author explicitly cannot do today — see whether
a Path Resample or a Path Drape worked.

The ordering falls out of dependency, not preference: **V1 first, because the inspector in V4 would inherit
the same normalisation bug and make it worse** — a histogram binned over its own data's extremes is Hesiod's
exact mistake (§2.2) and it is far more misleading with an axis on it than without.

### 5.2 The normalisation contract

This is the load-bearing section of V1.

**Rule 1 — the range is chosen by the port type, not by the data.**

| `PortType` | Range | Why |
| :--- | :--- | :--- |
| `MASK` | **Absolute 0..1, clamped, never rescaled** | A mask's range is what makes it a mask. Rescaling asserts something false |
| `HEIGHT` | Auto (per-grid min/max) **by default**, displayed, lockable | Terrain has no canonical range; a 4 m dune and a 400 m massif both need to be visible |
| `FLOAT` (unsigned field: distance, flow, wetness) | Auto, displayed, lockable | Same as HEIGHT, different ramp |
| `FLOAT` (signed field: curvature, delta) | Auto **symmetric about 0** — `±max(|min|,|max|)` | Zero must land in the middle of a diverging ramp or the ramp lies about sign |
| `INT` | Absolute, integer, **nearest-colour palette, never interpolated** | An index halfway between 3 and 4 is not a colour, it is a bug |
| `COLOR` | Absolute, blitted | Already colour |
| `PATH` | n/a — no grid is tapped at all | §6 |
| `VECTOR`, `CURVE`, `BOOL`, `TERRAIN_BUS` | No thumbnail; the node shows a type badge instead | A grid render of a non-grid is a lie shaped like data |

**Rule 2 — the range is on screen, always.** A **range chip** overlays the thumbnail's bottom edge:
`0.00 – 1.00` for a mask (fixed, dimmed, because it never changes), `-2.4 – 87.1 m` for a height, `AUTO`
or `LOCK` as a leading glyph. Two glyphs, six characters, and it is the difference between an image and a
measurement.

**Rule 3 — the range is lockable.** A click on the chip pins the current min/max. Subsequent refreshes
render against the pinned range. This is the direct fix for §4.2's second failure: with the range locked, a
gain slider visibly changes the picture. Locking is per-node, is view state, and does **not** persist into
the resource (§12.6).

**Rule 4 — a clamped pixel is marked.** Under LOCK, values outside the range render in a reserved
out-of-range colour rather than as the endpoint. Otherwise locking trades one silent lie for another.

### 5.3 The representation taxonomy

Chosen from the type by default (Rule 1), overridable per node by a right-click menu — Hesiod's two-axis
menu (§2.1 Q1) is the correct shape and we take it, with *type* replacing its `typeid` dispatch and its
port-name guessing.

| Representation | Default for | Notes |
| :--- | :--- | :--- |
| `HILLSHADE` | `HEIGHT` | What exists today. Relief-lit, needs an auto or locked range |
| `RAMP_SEQ` | unsigned `FLOAT` fields | Perceptually uniform, dark → light. Flow, distance, wetness |
| `RAMP_DIV` | signed `FLOAT` fields | Two-hued, neutral at 0. Curvature, deltas |
| `MASK_ALPHA` | `MASK` | Single tint at alpha = value **over a checkerboard**, so 0 and "no data" are distinguishable at a glance (§4.3) |
| `INDEX_PALETTE` | `INT` | Nearest-colour, no interpolation. Material and region indices |
| `PATH_GEOM` | `PATH` | Draws the polyline. **Never taps a grid.** §6.1 |
| `NO_DATA` | — | Not a choice: the swatch shown when a tap was requested and not served. §5.5 |
| `RAW_GRAY` | manual only | Absolute 0..1 grayscale, no lighting, no rescale. The "show me the actual numbers as brightness" escape hatch |

`HISTOGRAM` and `PROFILE` are deliberately **not** in this table — they are inspector representations
(§7), not thumbnail representations. A 128 px histogram with no axis is the artifact §2.2 warns about.

### 5.4 The opt-in downscale

For large brushes only, and never by default. `PREVIEW_SIZE` stays 128 for the thumbnail; what this adds is
a **solo/bake preview scale** for the case where a brush's footprint is large enough that a full-resolution
preview evaluation is the thing making the editor slow.

- Property on the graph, not the node. Values: `1:1` (default), `1:2`, `1:4`.
- **Anything but `1:1` puts a badge on screen** — §2.3's third conclusion, and the same
  `calibration-constants-must-be-stored-not-printed` discipline as the range chip. A downscaled preview of
  an erosion network is a *lie about the network's fineness*: channels merge, ridges round off, and the
  author tunes the wrong parameter to fix a problem that only the preview has.
- **It touches the preview only.** The bake is bit-identical with the option on and off, and V1's gate
  asserts exactly that.

Painting stays at full resolution. That is the point of the brush system — isolate an area and do the work
at full res — and this option does not change it.

### 5.5 Surfacing the failures (§4.3, §4.5)

**The tap API reports what it served.** `graph_eval_grid_taps` gains a companion key in its returned
Dictionary — an `unserved` `PackedInt32Array` of the slots that were substituted with zeros rather than
copied from a live buffer. The zero-fill stays (callers rely on one field per tap); what changes is that
the caller can now tell. `_preview_worker` renders `NO_DATA` for an unserved slot, and its own
`field.size()` mismatch drop does the same instead of `continue`.

That collapses §4.3's four causes to one: PATH nodes never tap (§6.1), unserved slots render `NO_DATA`, and
what remains black is genuinely flat — which the range chip then confirms by reading `0.00 – 0.00`.

**The non-lowering bail speaks.** When `compile_graph_program_multi` returns empty, every visible thumbnail
is marked stale — desaturated, with a badge — and the editor reports why, using `native_supported()` and
the op-id check to name the responsible node where it can. Same treatment for the other three silent
returns. A frozen thumbnail must never be indistinguishable from a live one.

---

### 5.6 Who the preview is looking through, and where view state lives

Two questions that turn out to be one. **Decided (2026-09-06):** view state stays on the resource, and the
open-graph gesture makes the binding explicit.

**View state lives on the resource, beside `preview_on`.** The range lock, the chosen representation and
the chosen channel sit where `preview_on` already sits, subject to §12.6 (none of them emits `changed`).
No editor-side side table, no second serialization site, no lifetime question about what happens to an
entry when a node is deleted.

**And the open-graph gesture binds the host brush, for the whole modifier stack.** Clicking *open graph* on
a brush sets that brush as the preview input source for **every `Pasture3DNodeGraph` in its modifier
stack**, not only the modifier whose graph was opened. So:

- The shared-graph ambiguity of §4.6 stops being reachable through the normal gesture. `host_brush` is
  always set when a graph is opened from a brush, so `_find_host_brush()`'s group scan — the tier that
  picks by scene order — is only reached by a standalone `.tres` with no host at all, which is the case it
  was written for.
- Switching graphs with the stack picker (`graph_editor.gd:300`) keeps the same brush. The picker already
  enumerates the host brush's stack; binding the brush rather than the modifier is what makes moving
  between its graphs coherent instead of re-triggering the search each time.
- Two brushes sharing a graph resource share its view state, and that is now the *correct* answer rather
  than an accident: what differs between them is which terrain you are looking through, and that is what
  the gesture sets. The lock, the representation and the channel are properties of the graph.

**A standalone graph with no host still previews**, over `PREVIEW_RECT` and `sample_brush_input`, exactly
as today. What changes is that the panel says which it is doing — the host brush's name, or *(no host)* —
because "this is a synthetic domain" and "this is your terrain" are not the same picture and currently look
identical.

---

## 6. (A2) PATH — the thumbnail and the viewport overlay

> **Read first, and this section has the most required reading of any:**
> `PASTURE3D_SPLINE_GRAPH_SPEC.md` **§7.5 (the derive family)** and **§8 (the geometry pre-pass)** — §8.2's
> compile-time PATH resolution and §8.4's staged compile are what "the path the graph resolved" means, and
> without them §6.3's trap reads as pedantry. Then §7.4 (the reshape family) for what Path Resample
> actually does, and its `PathShapeGate` [G] for the vertex-count cost constraint the overlay inherits.
> For the drawing half: `PASTURE3D_BRUSH_GIZMO_SPEC.md`, `PASTURE3D_BRUSH_GIZMO_INPUT_SPEC.md` and
> `PASTURE3D_BRUSH_GIZMO_SUBGIZMO_PHASES.md` — the overlay is a contribution to an existing
> `EditorNode3DGizmoPlugin`, not a new one, and the subgizmo id encoding is already spoken for.
> `PASTURE3D_SPLINE_SURFACE_SNAP_SPEC.md` for the drape-adjacent prior work.

### 6.1 The thumbnail: draw the geometry

A PATH node's grid slot is zeros by construction. Rendering it is rendering nothing. `PATH_GEOM` instead
rasterises the resolved path into the thumbnail's own bitmap — the same move Hesiod makes for
`hmap::Path` (§2.1 Q1) and the only part of Hesiod's preview code that is unambiguously right.

Drawn: the centreline, the vertices as dots, and the width envelope as two offset polylines at
`±half_width_at(s)`. Fitted to the path's own bounds, not the brush rect, so a short path is legible.
**No grid tap is requested for a PATH-typed output** — V1's gate counts this rather than inferring it.

But a 128 px thumbnail cannot answer "did the drape work". That needs the terrain.

### 6.2 The viewport overlay

**The requirement:** see the points of a Path Resample or a Path Drape in the 3D viewport, on the actual
terrain, to confirm they did what they claim.

**What it draws**, for a PATH node with `preview_on` and whose host brush is selected:

1. **Centreline** — the polyline through the resolved vertices, at their own heights when the path carries
   them, at the terrain surface when it does not.
2. **Vertices** — one dot each, using `Sprites._dot_sprite` as `brush_gizmo.gd:94` already does. This is
   the resample check: a 1 m resample shows 1 m spacing or it did not run.
3. **Width envelope** — left and right offsets at the per-vertex half-widths, as two more polylines. The
   affordance §2.3 found no prior art for.
4. **Drop lines** — optional short verticals from each vertex to the terrain below it. This is the drape
   check, and it is the one that actually matters: a correctly draped path has zero-length drop lines, and
   an undraped one is a straight line floating over a valley with visible drops. It reads at a glance and
   no other view does.

**Ownership.** A graph node is a `Resource` and has no gizmo. The overlay lives on the host brush's
`EditorNode3DGizmoPlugin` — `brush_gizmo.gd`, which already has `add_lines`, the dot sprites and the
subgizmo machinery. It is an additional `_redraw` contribution keyed on the brush's graph, not a new plugin.

### 6.3 The trap this feature is built around

**The overlay must read `derived_path()`. It must never call `eval_path()`.**

`Pasture3DGraphNodePathDerive.derive_without_grid(p_src)` returns the input path **unchanged**
(`pasture3d_graph_node_path_derive.gd:168`). So an overlay that asks a Path Drape for its path outside an
evaluation gets back the **undraped** line — and draws it, confidently, as the answer. An undraped line
drawn on terrain does not look broken. It looks like a path. The feature would ship, pass a naive test, and
be wrong exactly when the author most needs it: when the drape is not working.

`derived_path()` exists precisely because of this, and its own doc-comment says so:

```gdscript
## The path this node last HANDED THE GRAPH, or null if it has never been asked.
##
## Exists for the gates, and it is not a convenience. A test that calls `eval_path` itself measures a
## fresh call rather than the graph's — so it passes whether or not `_resolved_path_of` ever reached this
## node, and whether or not the memo served a stale answer.
```

That reasoning is one layer up from where it was written. It applies to the *feature*, not only to the test
— per `a-gate-that-calls-the-node-measures-nothing`, and this time the thing that would measure nothing is
the author's own eyes.

Consequences for V3:

- **`_returned` and `derived_path()` lift to `Pasture3DGraphNode`.** They live on the derive base today;
  the reshape family (`Pasture3DGraphNodePathShape` — Resample, Meanderize, …) has `eval_path_count` but no
  `_returned`, and the user's stated requirement names Path Resample first.
- **Never resolved ⇒ draw nothing.** Not the input, not a guess. Absence is the honest render, and the
  overlay says "not yet evaluated" rather than drawing a plausible line.
- **The overlay increments no counters.** V3's gate asserts `eval_path_count` is unchanged across a
  redraw, with a bake as the control that the counter moves at all.

### 6.4 What the overlay costs

Nothing at evaluation time, by construction — it reads a value the evaluation already stored. The redraw is
a gizmo redraw over a vertex list, bounded by the path's vertex count, which `PathShapeGate` [G] already
constrains. It does not participate in the graph revision (§12.6).

---

## 7. (A3) The inspector — the quantitative surface

> **Read first:** `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §8 (the editor) and §9 (how a node's face is built —
> the inspector is a second consumer of the same `input_port_types()` / `output_port_types()` declarations).
> `PASTURE3D_TERRAIN_GRAPH_USABILITY_SPEC.md` for what has already been decided about editor affordances,
> so the dock does not re-litigate a settled interaction. §5 of this document is a hard dependency: the
> histogram's whole value is that it bins over the **declared** range, and that contract lives there.

§2.3's second conclusion: every tool has one, we have none, and it is the half of visualization that a
thumbnail structurally cannot do.

A dockable panel, **pinnable** — it follows the graph editor's selection by default, and a pin button
freezes it on one node so the author can change selection without losing the reading. (Hesiod's viewer has
exactly this, `is_node_pinned` in `viewers/viewer.cpp`, and it is the right call.)

**Resolution: the inspector re-taps at its own.** Decided 2026-09-06. It does not upsample the thumbnail's
128 px field, because a probe reading an interpolated value and a histogram binning 16 384 samples of a
million-cell field are both *quantitatively wrong while looking quantitative* — the same category of defect
as §4.2, and worse here because an axis lends it authority. The inspector's tap is a second pass at its own
resolution, on the same debounce, **dispatched only while the dock is open** and cancelled by the same
token as the thumbnail pass.

> **Measured 2026-09-06** (§14.2 item 1, `project/bench/GraphInspectTapCostProbe.gd`): a 512 px second
> pass costs 8–33 ms depending on graph weight — at worst **27% of the 120 ms debounce**, off the main
> thread — and tap count is free within noise, so the second pass costs only its extra cells. **Ship the
> live re-tap at 512 px.** The fallback stays documented and unbuilt: if an author's graph ever does
> exceed the debounce, a *sample* button that taps once at bake resolution and freezes the result is the
> answer, because the numbers stay real and only their freshness is traded away. Upsampling never is.

**Contents, for a grid output:**

- **The field at inspector resolution** — larger than 128 px, tapped at that resolution, in the
  representation chosen by §5.3, with the same range chip and lock.
- **Probe.** Hover reports `(x, z) world → value`, in the field's own units, unnormalised. The single most
  useful thing in the entire document and the cheapest to build.
- **Histogram**, binned over the **declared** range (§5.2 Rule 1), with an axis. A mask spanning 0.28–0.32
  fills four bins near the left of a 0..1 axis — which is the true picture, and which is what Hesiod's
  histogram cannot show. V4's gate states this as a criterion because it is the whole reason the histogram
  is worth building.
- **min / max / mean**, as text.
- **The channel selector.** Decided 2026-09-07, and recorded here because until now no phase owned it. V2
  shipped the `(slot, channel)` tap mechanism (§8) with no way for an author to ask for a channel, so
  Erosion's `flow` / `ero` / `dep` / `wet` are reachable by the evaluator and unreachable by the editor.
  **The dock owns that choice**, not the thumbnail: V4 has to build channel selection anyway for its
  histogram to be useful on a solver — §8's closing line says so — and building it twice would put the
  answer to "which field am I looking at" in two places that can disagree. The selector is populated from
  the node's own `output_port_types()` declarations, like every other consumer of them, and it drives the
  probe, the histogram and the min/max/mean together: one selection, one field, or the numbers beneath the
  picture stop describing the picture.

  A channel whose slot reports `unserved` (§5, V1 [C]) renders `NO_DATA` and reports no statistics — it
  must not report zeros, for the reason §8 gives: an unreserved channel and a genuinely calm one are the
  same bytes, and treating them alike *is* the defect V2's `reserved` key exists to make visible.

  **Deliberately not in V4: a per-thumbnail channel picker.** A glanceable `flow` on the node face is a
  real want and a separate question — it needs a per-node persisted choice, which is view state on the
  resource (§12.6) and a slot→channel map in `graph_editor.gd`. It is left unscheduled rather than folded
  in silently, so that if it is built it is built as a *reuse* of the dock's selection and not as a second
  mechanism. §13 is where it would go if it is ruled out entirely.

**Contents, for a PATH output:**

- **Width profile** — `half_width_at(s)` against arc length. A taper reads as a slope; a Path Width driven
  by a flow field reads as a step at each confluence.
- **Height profile** — `height_at(s)` against arc length, with the terrain profile beneath it on the same
  axes. The difference between the two curves *is* the carve depth, plotted. A `NAN` (a heightless path)
  draws as a **gap**, never as 0 — a heightless path plotted at zero is a path at sea level, and it looks
  like a bug in the drape rather than an absence of data.
- **Vertex count, arc length, closed/open, `can_grade()`** as text.

---

## 8. Channel-addressable taps (the V2 mechanism)

> **Read first:** `PASTURE3D_NODE_ACCELERATION_GUIDE.md` **§5 (whole-graph lowering & the memory pool)** —
> V2 changes what that pool reserves, and **§3.2 (lowering safety rules & prevention checklist)** is the
> list of ways this exact area has gone wrong. Then §3.4 (the two-evaluator trap), because a tapped channel
> must agree across routes or it is a third evaluator nobody declared. `PASTURE3D_TERRAIN_GRAPH_GUIDE.md`
> §2 "Multiple outputs" for the port-index-equals-channel-index rule, and §11 item 4 for this bug's
> previous appearance. `PASTURE3D_SOLVER_NATIVE_ACCELERATION_SPEC.md` for what Erosion's four channels are
> and where they are written.

Two halves, and the phase is both or neither (§4.4).

**Half 1 — the tap API.** `graph_eval_grid_taps` takes `(slot, channel)` pairs rather than slots. The
returned Dictionary keys on a packed `slot * 4 + channel` (out_count is bounded at 4 by the SSA program's
`out_count` field), and gains the `unserved` list from §5.5.

**Half 2 — compiler allocation.** `compile_graph_program_multi` must allocate an aux buffer for a tapped
channel, exactly as it does for a channel an operand reads. Today allocation is demand-driven from wires,
and a tap is not a wire, so `want_aux` returns `nullptr` and the op skips the write.

**Blocks native: no.** Neither half adds an op. Half 1 is a signature widening in
`src/pasture_3d_graph_ops.cpp`; half 2 changes which buffers the existing compiler reserves. No new entry
in `graph_op_ids()`, so no graph-wide bail risk.

**Why this is worth a phase of its own:** Erosion's `flow`, `ero`, `dep` and `wet` are the four fields most
worth looking at in the entire palette and none of them can be previewed today without wiring them to the
output and back. It is also the prerequisite for V4's histogram being useful on a solver.

---

## 9. (B) Output — three owners, not one

> **Read first:** this section's three subsections each carry their own list, and they differ sharply —
> §9.1 is the layer stack, §9.2 is the exporter, §9.3/§9.4 are the water and road runtimes. For the section
> as a whole: `PASTURE3D_NODE_VOCABULARY.md` for what a "sink" is called here, and
> `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §4 (adding a node) — every node below is terminal, which §10 explains
> is a different mechanism from muting.

The single most important structural claim in this document: **"output" names three unrelated things**, and
building one mechanism for all three would produce a system that is wrong for at least two of them.

| | Owner | Trigger | Destination | Exists? |
| :--- | :--- | :--- | :--- | :--- |
| **B1** Terrain channels | The **bake/layer system** | The bake | `Pasture3DData` control & colour maps | Mechanism exists; the graph nodes do not |
| **B2** Files | New **sink nodes** | Explicit, never evaluation | Disk | `export_image` exists; nothing wires the graph to it |
| **B3** Runtime data | The **consumers** | Publish + staleness | `Pasture3DRoadRuntime`, `Pasture3DWaterBody` | **Consumers built; the arrow back is missing** |

### 9.1 B1 — terrain channel sinks (V5)

> **Read first, and §10.7 is not optional:** `PASTURE3D_LAYERS_GUIDE.md` **§10.7 (control & colour layers,
> done)** — the write API this phase calls already exists; **§8 (Tool API — nodes that draw into a layer)**
> for the four-step contract every sink must follow, especially step 2, *clear its own layer first*;
> §4.3 (the coverage/weight channel) and §5.1 (compositing) for why control is topmost-covered-wins and
> therefore why the mask is coverage rather than opacity; §11 and the map-type badge note for the settled
> decisions, including *"a layer's type is fixed at creation"*.
> Then `PASTURE3D_ROAD_CONNECTOR_GUIDE.md` and `pasture3d_road_connector.gd`'s `#holes` layer — the
> working precedent for exactly this shape. `PASTURE3D_LAYERS_HOLE_TESTING.md` for how it was verified
> in-editor rather than only headless.
> For the control-word review: `PASTURE3D_RELIEF_MATERIALS_GUIDE.md` §6 (selectors) and §7 (the materials),
> which is what actually *reads* base/overlay/blend, plus `PASTURE3D_MATERIAL_BRUSH_SPEC.md` and
> `PASTURE3D_TOOL_LAYER_ASSIGNMENT_SPEC.md`. `PASTURE3D_PLUGIN_FORK_GUIDE.md` only for the Terrain3D
> lineage the packing is inherited from — it is a fork-build document, not a format reference, and §12.9
> and §12.10 exist to protect compatibility with that lineage.

A graph that computes a slope mask should be able to paint with it. Today it cannot: the graph's output is
a height field and nothing else.

**The write machinery is already built, and this changes the phase substantially.**
`PASTURE3D_LAYERS_GUIDE.md` §10.7 (Phase 7, done 2026-06-14) generalised the layer stack past height:

- `Pasture3DData::create_owned_layer_typed(owner, name, blend, map_type)` with `TYPE_CONTROL` / `TYPE_COLOR`,
  plus `set_control_on_layer`, `set_hole_on_layer` and `set_color_on_layer`.
- **Control composites topmost-covered-wins — no arithmetic blend.** Each covered overlay bottom→top
  *fully replaces* the value. A packed `uint32` is not float-blendable, so this is structural rather than a
  policy choice.
- `pasture3d_road_connector.gd` already owns a second reserved control layer (`owner_id + "#holes"`), clears
  its footprint and re-carves idempotently. **A graph sink is that shape with a different mask source.**
- The guide's own remaining follow-up records that control layers *"are created via the tool API (the
  connector) only"* and that a hand-painting panel is missing. **V5 is a new tool-API consumer, which is the
  supported path**, not a new mechanism.

This is why §12.8 is not a close call, and it collapses V5 from "design a control writer" to "call the
functions that already exist, from a graph sink, with the mask as the coverage channel."

It also **settles the shape of the mask**: because control composites topmost-covered-wins at weight 1, a
graph mask is a **coverage** channel, not an opacity — which is the write-stencil rule below, arrived at
independently from the bug history and then confirmed by the storage format.

**Proposed nodes.** All are terminal (`has_output()` false), all write only at bake, none blocks native.

| Node | op id | Ports IN | Writes via | Blocks native? |
| :--- | :--- | :--- | :--- | :--- |
| `Control Sink` | — (terminal, §9.2) | `mask` (MASK), `base` (INT), `overlay` (INT), `blend` (MASK) | `set_control_on_layer` | **No** |
| `Color Sink` | — | `mask` (MASK), `color` (COLOR) | `set_color_on_layer` | **No** |
| `Hole Sink` | — | `mask` (MASK) | `set_hole_on_layer` | **No** |
| `Nav Sink` | — | `mask` (MASK) | `set_control_on_layer`, `nav` bit @1 | **No** |

None appears in the compiled program at all — they use §9.2's mechanism, so the native question does not
arise. What reaches the bake is a tap on each sink's *inputs*.

Each sink owns one reserved typed layer keyed on the host brush's `owner_id`, following
`PASTURE3D_LAYERS_GUIDE.md` §8.1's four-step contract: resolve/create, **clear its own layer in the affected
regions**, write, recomposite. Step 2 is what makes a re-bake idempotent and is the reason a moved brush
leaves no stale paint.

**Three rules that come from bugs already in the memory:**

1. **A sink writes only where its mask is non-zero.** The mask is not an opacity, it is a write stencil.
   Outside it, the pre-existing control word is byte-identical — which is the thing
   `road-batter-overwrites-other-roads` was.
2. **A sink writes through the layer its host brush owns**, so undo restores it in one action and
   `bake_all_brushes()`'s per-layer-owner clearing works unchanged. This is the reason B1 is not an
   "export": the bake system already owns write-area clipping, layer binding, undo and staleness, and a
   parallel path would have to reimplement all four.
3. **The sink never runs at preview.** V5's gate counts writes across a preview refresh.

**The control-word review** (the user's answer 3 asked for it). Layout at `pasture_3d_util.h:654–697`:

```
 31        27 26      22 21          14 13    10 9   7 6     3 2    1    0
[  base(5)  ][ overlay(5)][  blend(8)   ][rot(4)][sc(3)][free(4)][hole][nav][auto]
```

Findings:

- **There is no NONE sentinel, and there is no room for one.** Both index fields are 5 bits and Terrain3D
  allows 32 textures, so every one of the 32 values is legal. This is why `-1` silently meant texture 31
  (`road-tier-far-paint-built`).
  **The answer is not a sentinel.** NONE is expressed as *not writing* — a zero in the sink's mask. That
  needs no bits, cannot be misread as an index, and matches how every other write in the plugin is scoped.
  The node refuses a negative index outright, and V5 tests the refusal.
- **The four free bits (3–6) are not enough for a biome and should not be spent on one.** Sixteen biomes
  is a toy budget, and — decisively — anything stored there **cannot blend**. `blend(8)` interpolates base
  against overlay; a biome id in a raw 4-bit field would hard-edge at every boundary, which is exactly the
  artifact the base/overlay/blend split exists to avoid. §12.10.
- **Spend nothing. All four bits stay reserved and unread.** §12.15. An earlier draft spent bit 6 on
  `graph_owned`; that is withdrawn. Provenance already exists one level up — each sink owns a reserved
  typed layer keyed on `owner_id` — and the only thing a bit could serve is a consumer of the
  *composited* map, after layer identity is gone. **Verified 2026-09-06: no such consumer exists.** The
  two sites that read the composited control map and act on it, `pasture3d_splat.gd:199` and
  `pasture3d_road_brush.gd:1593`, both read it to **preserve** what is underneath (base texture, nav and
  hole bits); neither arbitrates a write. Bits 3–6 have no accessor in `src/pasture_3d_util.h:654–697`
  and no shift anywhere in `src/`.
- **The `nav` bit is already there and we do not write it.** A slope-and-water mask from the graph is
  precisely what wants to write it, and `Nav Sink` is four lines once `Control Sink` exists.

A biome, if one is wanted later, is a **derived read** of `(base, overlay, blend)` plus the graph's own
masks — not a stored field. That is a separate document.

### 9.1a The prerequisite §12.16 exposes: control and colour hand paint does not go through a layer

> **Read first:** `PASTURE3D_LAYERS_GUIDE.md` §5.1 (the composite target and the dense base), §8.1 (the
> four-step tool-API contract), §10.7 (control & colour layers, and its "created via the tool API only"
> follow-up), §11 (map-type badge). Then `src/pasture_3d_editor.cpp:100–120` and `:1030–1060`, and
> `src/pasture_3d_data.cpp:1778` (`_ensure_typed_base`) and `:1146–1180` (`composite_region`).

§12.16's guarantee — a sink's layer refuses strokes, so a touch-up goes on a layer above — **is built for
`TYPE_HEIGHT` only.** Every V5 sink is control or colour. Traced 2026-09-06:

1. `Pasture3DEditor::start_operation` captures `_stroke_layer` **only** when the active layer's map type is
   `TYPE_HEIGHT` (`pasture_3d_editor.cpp:1043`). The `is_locked() || is_reserved()` refusal at `:1049` sits
   *inside* that branch, so **it never fires for a control or colour layer.**
2. `route_to_layer` is `_stroke_layer.is_valid() && map_type == TYPE_HEIGHT` (`:108`). Control and colour
   strokes take the `:323` / `:496` branches and write the **region map directly** — no layer is targeted,
   so there is no layer to reserve, refuse, or stack a touch-up above.
3. `_ensure_typed_base` (`pasture_3d_data.cpp:1778`) seeds "Control Base" **once**, from each region's
   current hand-authored control map, at the moment the first control layer is created, and marks it
   `set_reserved(true)`.
4. `composite_region` runs the control path only when `_layer_stack->has_overlay_of_type(TYPE_CONTROL)`
   (`:1168`). Before the first control overlay exists this is false, and the region map is the source of
   truth — which is why hand texture paint is safe on a plain terrain today.

**Put together: the first Control Sink flips the terrain from "the region control map is the truth" to
"the region control map is Control Base ⊕ overlays" — and Control Base is a snapshot taken at the instant
of the flip.** Every hand texture paint made *after* that flip writes the composite target, and is erased
the next time anything composites those cells (a bake, a road repaint, another sink write). Nothing adopts
those direct writes back into the base: `_adopt_region_into_bases` skips any layer that already
`has_region(loc)`, so it seeds new regions only.

Two consequences, and they are different in kind.

**For V5, this is a prerequisite, not a footnote.** Shipping control/colour sinks onto the current stroke
routing would give the user a rule (§12.16) whose mechanism does not exist for the map types the rule is
about: they cannot make a hand-painting control layer above the sink, because hand control paint does not
target a layer at all. **V5 must first route control and colour strokes through the layer stack the way
height strokes are routed** — extend the `TYPE_HEIGHT` guard at `:1043` and the `route_to_layer` test at
`:108` to the typed layers §10.7 already built, so `is_reserved()` refuses a stroke on a sink's layer and
an ordinary control layer above it accepts one. This is the write machinery §9.1's "no new write
machinery" claim did **not** cover; that claim was about `set_control_on_layer`, which is the tool-API
side and is genuinely built.

**Independently, this looks reachable today, and it is not this spec's to fix.** The road connector
already creates control layers (`PASTURE3D_LAYERS_GUIDE.md` §10.7, the `#holes` layer), which sets
`has_overlay_of_type(TYPE_CONTROL)` on any terrain carrying a road. By the trace above, hand texture paint
on such a terrain is then live until something composites over it. **I have read this path but not
reproduced it**, so it is stated as a code reading rather than a confirmed bug — the check is one gate:
paint control by hand on a terrain with a road, composite that rect, and compare. If it reproduces it is
its own fix with its own gate, ahead of V5 and outside this spec.

### 9.2 B2 — file sinks (V6), and why we need no `auto_export`

> **Read first:** `src/pasture_3d_data.cpp:2600` `Pasture3DData::export_image` and its surfacing in
> `project/addons/pasture_3d/tools/importer.gd` — the format writers V6 delegates to, and the reason §12.8's
> "no second export path" applies to files as well as to channels. `PASTURE3D_LAYERS_GUIDE.md` §7
> (persistence & migration) for what is editor-only data and what actually ships, since an export must
> never write the former. `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §9 for `SLOT_SPINS` and the never-restate-a-
> range rule, which applies to every parameter these sinks expose.
> `pasture3d_sim_manager.gd:1525` `bake_all_brushes()` is `Export All`'s model — read it before writing the
> registry walk, not after.

Hesiod's problem (§2.1 Q3) is that its export node is a node in the graph, so it runs when the graph runs,
so it needs a flag to stop it, so batch export needs to rewrite the flag, so the GUI needs to detect export
nodes by name. Four mechanisms, one root cause.

**We have a better primitive already: the tap system is an export mechanism.** An export node is a tap with
a filename.

So:

> **An export sink declares `has_output()` false.** Nothing can wire *from* it, so it is never an ancestor
> of the graph output or of a preview root, so `compile_graph_program_multi` never emits an op for it. The
> file write lives in a separate entry point, `export_graph_outputs()`, which compiles with the sink's
> **input** node as a root, taps that slot, and writes. The evaluator has no code path that can reach a
> file write.

**The pattern already exists and is already called a sink.** `pasture3d_graph_node_output.gd:34` overrides
`has_output()` to false with the comment *"The sink exposes no output port — its value is the graph's
result, read by the host, not by another node."* An export sink is the same shape with a different
consumer. The editor already handles it: `graph_editor.gd:780` gates the solo and preview buttons on
`has_output()`, so a sink correctly gets neither, and therefore cannot become a preview root either.

**It is deliberately *not* modelled on mute.** A muted node is **not** rewired out — it lowers to op 12,
`output`, a passthrough (`pasture3d_terrain_graph.gd:1304`, and `_lower_node_op`'s doc-comment says so).
Mute costs an op. Terminality costs nothing, because there is nothing downstream to pass through to.

Consequences, all of them good:

- **No `auto_export` flag.** There is nothing to suppress.
- **Zero native risk.** No op, no `graph_op_ids()` entry, no `blocks_native()`. Adding an export sink
  cannot cost the graph its GPU route — which, given that a graph-wide bail is silent, is not a small
  property.
- **Zero evaluation cost.** Adding a sink leaves the compiled program byte-identical, because the compiler
  never visits it. V6's gate asserts op-count equality against exactly that.
- **A sink is terminal, never mid-chain.** You wire the field you want written into it as a leaf, alongside
  whatever else consumes that field. This is also how Hesiod's export nodes are shaped, and it is the one
  structural thing it got right in this area.
- **Batch is a parameter of the action, not a mutation of the graph.** `Export All` takes a base path; each
  sink carries a relative filename; they are joined at export time. Nothing is rewritten, nothing is
  flipped and restored, and a cancelled export leaves the graph untouched.

**Proposed node set.** Every one is terminal (`has_output()` false), so the "Blocks native" column is `No` for all of them and is
therefore omitted.

| Node | Ports IN | Artifact | Formats | Fires on |
| :--- | :--- | :--- | :--- | :--- |
| `Export Heightmap` | `height` (HEIGHT) | Elevation raster | r16, exr, png16 | Explicit |
| `Export Mask` | `mask` (MASK) | Single-channel mask | png8, png16, exr | Explicit |
| `Export Normal Map` | `height` (HEIGHT), `normal` (VECTOR, optional) | Tangent-space normals | png8 (RGB) | Explicit |
| `Export Splat` | `r`,`g`,`b`,`a` (MASK ×4) | Packed 4-channel weight map | png8, png16 | Explicit |
| `Export Index Map` | `index` (INT) | Material/region indices, nearest, no filtering | png8, exr | Explicit |

`Export Heightmap` and friends delegate to `Pasture3DData::export_image`'s format writers where the shapes
line up — this is not a second export path (§12.8), it is the graph's door into the existing one.

**`Export Normal Map` declares both inputs; only the derived one works in V6.** Decided 2026-09-06: derive
from `height` by default, with an optional `normal` VECTOR port for authored normals. The port is declared
now so the node's shape does not change later — but the SSA program cannot carry a vector grid, and giving
it one is a compiler and buffer-layout change, not a node. So until that lands:

> **A wired `normal` port is refused with a named warning, never silently ignored.** An optional input that
> quietly falls back to deriving is the zeros-impostor pattern again (§4.4) wearing a different hat — the
> author wires a vector field, gets a plausible normal map derived from something else entirely, and has no
> way to tell. Refusing is the honest failure and it costs one warning.

Deriving remains the default and the recommended path regardless: a normal map derived from the exact
height field you exported is consistent with it by construction, which is the property that actually
matters at the other end.

**What each carries:** a relative `filename`, a `format`, an explicit `range` for the quantised formats
(png8/png16 need a divisor, and per `calibration-constants-must-be-stored-not-printed` it is written to a
sidecar, not printed to the console), and the world rect + resolution the tap is evaluated at.

**`Export All`** is modelled on `bake_all_brushes()` (`pasture3d_sim_manager.gd:1525`): walk a registry,
one action, cancellable, print a report naming every file written. It does **not** need the per-layer-owner
subtlety that function has — files have no layers — but it does need the cancellation and the report.

### 9.3 B3 — runtime data (V7a): the consumers exist, the arrow does not

> **Read first:** `PASTURE3D_WATER_GUIDE.md` **§6 (querying the water from code)** and §5 (`Pasture3DBuoy`)
> — that is the live contract V7a and V7b must not break, and §4 for what a `Pasture3DPool` versus a
> `Pasture3DStream` already is. Then `PASTURE3D_WATER_BODIES_SPEC.md` and
> `PASTURE3D_BUOY_REMEDIATION_SPEC.md` for what the buoyancy path assumes about the surface — §9.4 answers
> that, and §14.2 item 2 is what remains of it.
> `PASTURE3D_ROAD_CONNECTOR_GUIDE.md` for the road side, `PASTURE3D_ROAD_STALENESS_AND_COST_SPEC.md`
> for the staleness vocabulary already in use (do not invent a second one), and
> `PASTURE3D_SPLINE_GRAPH_SPEC.md` §12.3, which is the open item this phase closes.

This is not "export splines to a file". Two mature runtime consumers already ship:

- **`Pasture3DRoadRuntime`** (`roads/pasture3d_road_runtime.gd`) — a `Resource` of `runs`, `links` and
  `built_at`, with `run_by_id` and `locate(world) → {run_id, s, t, distance, on_road, on_corridor,
  surface}`. Loads with no editor and no terrain. `Pasture3DRoadLaneConnector` carries the legal junction
  paths. Its header states the contract: *Pasture3D publishes road and lane DATA, and a project's traffic,
  AI and race logic are that project's to write.*
- **`Pasture3DWaterBody`** (`connectors/pasture3d_water_body.gd`) — `get_water_height(p_global_xz)`
  memoised on `Engine.get_physics_frames()`, a Gerstner inverse in `solve_domain()`, and `apply_buoyancy()`.
  `Pasture3DBuoy` queries it twice a tick.

**What is missing is the arrow back.** `PASTURE3D_SPLINE_GRAPH_SPEC.md` §12.3 already names it: the solve
can spawn a Pond, the Pond cannot read the solve, and editing terrain under one desynchronises them with no
signal. The same shape holds for a graph-derived river course and a road runtime.

So V7a is a **publish + staleness contract**, not a file format:

- **`Path Publish`** — hands a resolved PATH to a named runtime consumer. Terminal (§9.2's mechanism —
  `has_output()` false), fires at bake.
- **`Water Surface Publish`** — hands a resolved PATH to a `Pasture3DWaterBody`. **One node, two consumers,
  discriminated by `Pasture3DGraphPath.closed`:**
  - **Closed loop → `Pasture3DPool`.** Its header already reads *"still water filling a closed outline"*,
    its `source_spline` / `curve` is exactly a closed loop, and it warns when handed an open one. A pool
    receives an **extent**, not a level — it stays flat (§14.1 Q4). No runtime query path changes, so this
    half is **V7a**.
  - **Open path with heights → `Pasture3DStream`.** This is the sloped case, and it is **V7b** (§9.4).

  The discriminant is not a mode switch anyone sets: `closed` is already a property of the path, the two
  bodies already split on it, and a Pool already refuses an open curve. The publish node reads what the
  path is and hands it to whichever body is wired.
- **A digest on both sides.** The producer stamps the content digest it published; the consumer **stores**
  it. Staleness is `consumer.stored_digest != producer.current_digest`, checked at bake and surfaced as a
  warning. Per `check-derived-values-outside-the-chain`, V7a's gate asserts the *consumer's stored* digest,
  not the producer's — comparing a producer's digest to itself proves only that hashing is a function.
- **A stale consumer still answers.** `locate()` and `get_water_height()` keep working on the last good
  data and report `stale`. A runtime consumer that starts returning nulls because the editor changed is a
  crash in a shipped game.

---

### 9.4 The sloped water surface (V7b)

> **Read first:** `PASTURE3D_WATER_GUIDE.md` §6 (querying water from code) and §5 (`Pasture3DBuoy`) — the
> live contract V7b must not break — then `pasture3d_stream.gd` around `_apply_bank_surface`, `_bank_crest`
> and `_effective_bank_search` (the code §9.4.3 deletes), and `water_surface.gdshaderinc`, which carries
> **no level uniform**: parity with the shader is structural, through `_ribbon_rows`, not transcribed.
> Phase 7's existing water gate for criterion [B]'s 0.009 m budget and its 400 kg boat fixture.


**The risk here was overstated when this was asked, and the code says so.** `Pasture3DWaterBody` does not
assume a plane at the level that matters. `get_water_height` is already two terms:

```gdscript
_height_cache_y = _still_surface_y(p_global_xz) + _wave_offset(p_global_xz)
```

`_still_surface_y(p_global_xz)` (`pasture3d_water_body.gd:320`) is a **virtual that already takes the world
XZ**, and its own doc-comment names this exact case:

> *The STILL water level at a world XZ, before waves. The node's own Y for a flat sheet; a stream overrides
> it because a river runs downhill and has no single level.*

`pasture3d_stream.gd:283` is that override, shipped and in use. **A sloped water surface is not a new
capability — it is an existing one with a third implementation.** The Gerstner inverse is not involved:
`solve_domain` operates on `_wave_domain()`, wave phase relative to the body origin, which a varying still
level does not touch. The base is kept deliberately cheap (*"a flat body must be able to answer it without
touching its geometry"*), and a graph-published surface must respect that: what reaches the physics tick is
a **baked array of rows**, queried by the existing nearest-row index. The graph is never evaluated there.

**The real constraint is shader parity, and it is already written down** in `_wave_offset`'s comment:

> *Whatever answers it, it has to agree with the SHADER, because a buoy floats on what this returns and a
> player sees what the shader drew. Phase 7 criterion D puts a 400 kg boat on a river and requires the two
> within 0.009 m.*

#### 9.4.1 How the stream actually keeps that agreement — and it is not a transcription

An earlier draft of this section framed the choice as *transcribe the level into the shader, or feed it a
sampler*. **Both are wrong, and the code is clearer than either.**

`water_surface.gdshaderinc:14` reads `vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;` and
line 83 writes `VERTEX = (VIEW_MATRIX * vec4(wave.position, 1.0)).xyz;`. There is **no level uniform and no
level sampler**. The shader displaces waves *from the vertex it was given*. The still level lives in the
**mesh geometry** — `_build_surface`'s comment says so outright: *"The mesh carries real Y per row, which is
the whole reason `_still_surface_y` is a hook rather than a constant."*

So parity is **structural, not maintained**: `_ribbon_rows` (a `PackedVector3Array`, one row per station,
carrying real Y) is written once, the mesh is built from it, and `_still_surface_y` queries the same array
through `_ribbon_surface_at`. One source, two readers. The only residual error is the difference between
the mesh's triangulation and the row interpolation, which is what 0.009 m is measuring.

**That is the property V7b must preserve, and it decides the design:** a graph-published surface must
become `_ribbon_rows` — not a second source that the mesh and the query each interpret.

#### 9.4.2 What V7b actually changes: `_apply_bank_surface`, and nothing downstream

`Pasture3DStream` already derives its level from terrain. `_apply_bank_surface`
(`pasture3d_stream.gd:753`) is one function that writes two things:

| It writes | What it is | Today |
| :--- | :--- | :--- |
| the rows' Y | the still surface, per station | lower of the two `_bank_crest` samples, minus `bank_height`; falls back to `c.y + fill_offset` where the search fails (`sampled[r] == 0`) |
| `_ribbon_half_l` / `_ribbon_half_r` | the waterline, **asymmetric, per station** | `_waterline_half` per side; falls back to `ribbon_half_width` |

**V7b replaces that function's inputs with the published PATH** — heights → the rows' Y, per-vertex
half-widths → `_ribbon_half_l` / `_ribbon_half_r` — and changes nothing downstream. The mesh builder,
`_ribbon_surface_at`, the spatial cell index, `_contains_local`, the wave code and the whole parity
apparatus are untouched, because they all read those same three arrays.

**This is also why §14.1 Q3's answer costs nothing.** "The published width envelope defines the extent" is
not new work: `_contains_local` is already `return _ribbon_surface_at(p_local_xz)[0]`
(`pasture3d_stream.gd:276`), and `_ribbon_surface_at` already consults the per-row half-widths. Containment
already goes through the arrays the graph will fill. The graph owns level *and* edge by filling two arrays
that already exist and are already asymmetric.

#### 9.4.3 The bank measurement is deleted, and that is the risk

Decided 2026-09-06: **the graph replaces the bank measurement entirely.** `_bank_crest`, `_waterline_half`,
`_effective_bank_search` and their exports come out, per `pre-stack-code-gets-deleted` — superseded code is
removed outright, not shimmed. Two tiers remain: **published rows**, then **`c.y + fill_offset`** for a
stream over a bare mesh with no terrain, which is the fallback that already exists and must survive.

The danger is not the deletion, it is the silent downgrade. What comes out is not naive: it takes the
**lower** of two crests (water cannot stand higher than the side it would spill over), auto-derives
`bank_search_width` from the host Trough's `bed_half_width + bank_width`, and smooths the result. A graph
that reproduces three of those four gives every river in the project a slightly wrong waterline, and
nothing fails.

So V7b ships **a preset graph** — the one `Add Water` on a Trough wires up — and its gate's first criterion
is that the preset reproduces the deleted measurement on a fixture, **compared against the old code before
it is removed**. Any existing `Pasture3DStream` in a scene migrates onto that preset; a stream that cannot
be migrated warns rather than silently falling through to `fill_offset`, because a river that quietly drops
to bed-plus-offset looks like a river.

#### 9.4.4 Why V7 splits

V7a (paths, roads, closed loops to a Pool, the digest and staleness contract) touches no runtime query path
and ships on its own. V7b touches a function `Pasture3DBuoy` calls twice per physics tick **and deletes a
shipped measurement**, so it is gated separately — a water regression must not be able to arrive attached
to a road publish. Same shape as S7a/S7b in `PASTURE3D_SPLINE_GRAPH_SPEC.md`.

**Phase 7 criterion D is the control V7b must not regress**, and V7b's gate asserts against that existing
bound rather than inventing a new one.

---

## 10. Native-lowering declarations

> **Read first:** `PASTURE3D_NODE_ACCELERATION_GUIDE.md` **§2 Step 0 ("decide whether the node is allowed
> to be visible AT ALL")** — every node proposed here must survive that gate before anything else — then
> §3.2 (lowering safety rules & prevention checklist) and §3.3 (runtime guarantees).
> `PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md` for the `[Dev/GD]` rule, which these sinks are an
> unusual case of: they have no kernel to be a twin of. `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §4 (adding a
> node) for the registration steps, and §4.4 for what native acceleration actually obliges a node to.

Required by the brief: for every proposed node, whether it blocks native and why that is acceptable.

| Node | `blocks_native()` | New `graph_op_ids()` entry? | Reasoning |
| :--- | :--- | :--- | :--- |
| Every B1 sink (§9.1) | **false** | **No** | Terminal: `has_output()` false, so the compiler never **visits** it |
| Every B2 export sink (§9.2) | **false** | **No** | Same — and note this is *not* the mute mechanism |
| `Path Publish`, `Water Surface Publish` (§9.3) | **false** | **No** | Same |

> **Not "compiled out" — the distinction costs an op if you get it wrong.** A muted node is *not* rewired
> away: `pasture3d_terrain_graph.gd:1304` lowers it to op 12 (passthrough), so a mute still occupies a slot
> and still costs an op. A terminal sink is different in kind — it is never an ancestor of a root, so the
> compiler's walk never reaches it and there is nothing to lower. Do not implement a sink by muting.

**Every node this document proposes is terminal — `has_output()` false — so the compiler never emits an op
for it.** That is not a coincidence, it is the design: nothing can wire from a sink, so a sink is never an
ancestor of a root, so there is nothing for it to compute. `Pasture3DGraphNodeOutput` is the existing node
of this shape and the editor already handles it (`graph_editor.gd:780` gates the solo and preview buttons
on `has_output()`). The graph-wide bail is a hazard for *operators*, and this document adds none.

**The registry sweeps will pick these up the day they are registered.** `GraphAllNodeSocketsGate`,
`GraphNodeEditorUIGate` and `GraphPaletteAndConstantsGate` walk the registry rather than a name list, which
is the discipline `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §10 asks for — but two of them assert every registered
node is *evaluable*, and a terminal sink is not evaluable in the usual sense. **V5 and V6 must check those
three gates against a no-output node before adding one**; `Output` and `Reroute` are the only precedents
and both are special-cased elsewhere.

The two phases that touch C++ (V2's tap widening, and V1's `unserved` reporting) change existing functions'
signatures and the compiler's buffer reservation. Neither adds an op tag. Per
`op-ids-omission-drops-graph-to-gdscript`, the check that matters is `native_supported()` returning true on
a graph containing the new nodes, and V5 and V6 both assert it directly rather than inferring it from
output that looks right.

---

## 11. Phases

> **Read first:** `PASTURE3D_NODE_ACCELERATION_GUIDE.md` **§3.4 (the two-evaluator trap)** and **§3.8 (gate
> discipline, from a full sweep of `bench/*.tscn`)** — these are the house rules every gate below is written
> against. `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §10 lists which existing gate owns which claim, and *"which
> gate owns this"* is the right first question about any change here; it also carries the headless notes
> (GPU gates need a window and must report NO-SIGNAL rather than pass; `_schedule_refresh` is editor-only,
> so assert the returned decision).
> `PASTURE3D_PR_WORKFLOW_GUIDE.md` §"Adding a gate" for registration and CI, and **§"The demo data
> problem"** before running anything — a gate that touches `data_directory` can rewrite the demo terrain,
> and a clean `git status` afterwards proves nothing about what it did.

Each phase ships on its own and each has a gate whose controls can fail. Per `bench-gate-practices`, every
criterion has a control that fails, and per `gate-pass-can-mean-nothing-ran`, every gate accounts for
silent criteria — a criterion that threw before asserting is reported as a failure, not skipped.

| Phase | Scope | Gate |
| :--- | :--- | :--- |
| **V1** | **The representation & range contract** (§5): type→representation from `output_port_types()`, the range chip, MASK absolute, signed/unsigned ramps, the lock + out-of-range marking, `INDEX_PALETTE`, the `unserved` tap report, `NO_DATA`, the non-lowering bail surfaced by name, `PATH_GEOM` thumbnails, the opt-in downscale + badge, **and §5.6's explicit host binding** (open-graph sets the brush for every graph in its modifier stack; the panel names the host or says *(no host)*). GDScript in `graph_editor.gd` plus a widened `hillshade_image_grid` family and one C++ return-key. | `GraphPreviewReprGate`: **[A]** a MASK output renders identically whether its values span 0..1 or 0.28..0.32 — controls: a HEIGHT output with the same two ranges renders *differently* (so the criterion measures the type rule, not a dead renderer), and the mask fixture is asserted non-uniform so "both black" cannot pass; **[B]** the range chip's numbers equal a min/max computed outside the preview path — control: with the range LOCKED the chip reports the locked numbers and the image stops moving when the data's range moves (`check-derived-values-outside-the-chain`); **[C]** an unserved tap renders `NO_DATA` and a genuinely-zero field renders black, and **the two images differ** — control: the same slot served renders neither; **[D]** a graph that does not lower marks every visible thumbnail stale and names the blocking op — asserted through `native_supported()` directly — control: a lowering graph marks none; **[E]** a PATH-typed output requests **zero** grid taps — counted at the tap call, not inferred — control: a HEIGHT output requests one; **[F]** the downscale option leaves the bake bit-identical — control: the preview image differs, so the option is not a no-op; **[G]** toggling `preview_on` performs no evaluation — counted — control: editing a parameter does increment it; **[H]** with **two brushes hosting the same graph resource**, opening the graph from either one previews over *that* brush's footprint — asserted on the rect and grid size the tap actually ran with — controls: the two fixtures' footprints must differ (so a shared rect cannot pass), and the pre-change build must **fail** this criterion, since scene order alone decides today (§4.6). |
| **V2** | **Channel-addressable taps** (§8): `(slot, channel)` pairs through `graph_eval_grid_taps`, and the compiler half that allocates an aux buffer for a tapped channel. C++ in `pasture_3d_graph_ops.cpp` + `compile_graph_program_multi`. Erosion's `flow`/`ero`/`dep`/`wet` become previewable. | `GraphPreviewChannelGate`: **[A]** tapping Erosion channel 1 returns the same field the graph output returns when `flow` is wired to the output — control: channel 0 and channel 1 differ, so the criterion cannot pass by reading one buffer twice; **[B]** **the allocation half is what is being measured** — with the compiler half disabled the tap returns all-zeros, which is the failure that renders as plausible still water; assert on the compiler's aux reservation record, and the control is that removing *either* half fails this criterion; **[C]** adding a tap does not change the graph output — bit-identical — controls: the output is non-flat with and without, so two flat fields cannot agree vacuously; **[D]** a tap on a channel ≥ `out_count` is reported `unserved` (V1 [C]), not served as zeros. |
| **V3** | **The viewport PATH overlay** (§6.2): `_returned` / `derived_path()` lifted to `Pasture3DGraphNode`, the gizmo contribution on `brush_gizmo.gd` — centreline, vertices, width envelope, drop lines. Independent of V1/V2; **bringable forward.** | `GraphPathOverlayGate`: **[A]** the overlay draws the path the graph resolved — asserted through `derived_path()` **and** the drawn vertex array — control: **with the drape's capture suppressed the overlay draws NOTHING**, not the undraped input. This control is the criterion (§6.3); **[B]** `eval_path_count` does not move across a redraw — counted — control: a bake does move it; **[C]** a draped path's drawn heights match the surface at its vertices within one cell — controls: the *undraped* path does not, and the fixture is asserted non-flat; **[D]** the width envelope tracks per-vertex half-widths — control: a constant-width path draws parallel offsets, a tapered one does not; **[E]** a 1 m resample draws vertices 1 m apart AND the overlay's vertex count equals the resolved path's — control: the pre-resample count differs, so "drew the input" cannot pass; **[F]** toggling `preview_on` redraws the overlay and does **not** bump the graph revision — control: moving a spline point does bump it. |
| **V4** | **The inspector dock** (§7): pinnable, selection-following; probe, histogram on the declared range with an axis, min/max/mean, and the PATH width and height profiles against arc length. **Re-taps at its own resolution** (§7), on the shared debounce, dispatched only while the dock is open. Depends on V1 (the range contract) and reads V2's channels where present, through **the channel selector §7 assigns to this phase** (decided 2026-09-07: the dock owns the choice; a per-thumbnail picker is explicitly not in scope). | `GraphInspectGate`: **[A]** the probe reports the field's value at a cell, read outside the preview path — control: a neighbouring cell differs, so a constant fixture cannot pass; **[A2]** the inspector's field was tapped at the inspector's resolution, not upsampled — asserted on the tap's requested grid size — control: the thumbnail pass in the same refresh requested 128, so a single shared tap cannot pass; **[A3]** no inspector tap is dispatched while the dock is closed — counted — control: opening it dispatches one; **[B]** **the histogram bins over the declared range, not the data's** — a mask spanning 0.28–0.32 fills bins near the left of a 0..1 axis and leaves the rest empty — control: the same data on a HEIGHT port with AUTO range does fill the axis, so the criterion measures the rule and not the binner; **[C]** the width profile equals `half_width_at(s)` sampled independently — control: a constant-width path is flat and a tapered one is not; **[D]** a heightless path's profile draws a **gap**, and the gap is asserted as absent-data rather than as zeros — control: a path carrying heights draws no gap; **[E]** pinning holds the node across a selection change — control: unpinned follows it; **[F]** selecting Erosion's `flow` channel moves the probe, the histogram AND the min/max/mean together to that channel's field, compared against a `graph_eval_grid_taps` call made outside the dock — controls: channel 0 and channel 1 differ on the fixture (so reading one buffer twice cannot pass), and a channel the compiler did **not** reserve reports `NO_DATA` with no statistics rather than zeros, which is the distinction V2's `reserved` key was added to make observable. |
| **V5** | **B1 terrain channel sinks** (§9.1): `Control Sink`, `Color Sink`, `Hole Sink`, `Nav Sink`, each owning one reserved typed layer via `create_owned_layer_typed` and writing through `set_control_on_layer` / `set_color_on_layer` / `set_hole_on_layer`. The write-stencil rule, the §8.1 clear-first contract, the negative-index refusal. **No `graph_owned` bit — all four free bits stay reserved (§12.15).** **Starts with the §9.1a prerequisite:** route control and colour strokes through the layer stack as height strokes already are (`pasture_3d_editor.cpp:108`, `:1043`), so a sink's reserved layer refuses a hand stroke and a touch-up layer above it accepts one (§12.16). Without that step the sinks ship a rule whose mechanism does not exist for their map types. The tool-API side (`set_control_on_layer` etc.) is built — `PASTURE3D_LAYERS_GUIDE.md` §10.7 — the *stroke routing* is not. | `GraphChannelSinkGate`: **[A]** a sink writes only where its mask is non-zero — control: outside the mask the pre-existing control word is **byte-identical**, and the fixture has pre-existing non-default paint so "everything was zero anyway" cannot pass; **[B]** the write goes through the sink's own reserved typed layer, so one undo restores it and a **re-bake after moving the brush leaves no stale paint** (the §8.1 step-2 property) — controls: undo after a hand paint on a touch-up layer **above** the sink (the only place a hand paint can land now — §12.16) restores that paint and not the graph's, and skipping the clear leaves the old footprint behind; **[B2]** the three registry sweeps (`GraphAllNodeSocketsGate`, `GraphNodeEditorUIGate`, `GraphPaletteAndConstantsGate`) still pass with a no-output node registered (§10); **[C]** a negative index is **refused at the node**, and the refusal is what is tested — control: index 31 is accepted, so the refusal is not a blanket rejection (`road-tier-far-paint-built`); **[D]** §12.16 holds for control and colour, which is the §9.1a prerequisite's whole point: a hand stroke aimed at a sink's reserved layer is **refused** and reports `BLOCK_LOCKED`, and the sink's cells are byte-identical after the attempt — **controls:** (i) the same stroke on an ordinary control layer *above* the sink **succeeds**, so the refusal is not "control strokes are broken", (ii) that touch-up survives a full graph re-bake byte-identical, so topmost-covered-wins is actually running and not merely configured, and (iii) with the sink's layer marked un-reserved the stroke is accepted — so [D] is measuring `is_reserved()` and not some unrelated refusal; **[D2]** no bit outside the documented layout is ever set: after every sink writes, `control & 0x78` is zero across the whole fixture (§12.15) — control: the assertion fails when a bit is deliberately set, so it can distinguish "nothing wrote there" from "nothing ran"; **[E]** `native_supported()` is **true** on a graph containing every sink, and the compiled op count equals the same graph without them — control: the same graph with a known blocker returns false; **[F]** a preview refresh performs zero writes — counted — control: a bake writes. |
| **V6** | **B2 export sinks + `Export All`** (§9.2): five terminal sinks, `export_graph_outputs()`, the sidecar range record, the registry walk modelled on `bake_all_brushes()`. | `GraphExportGate`: **[A]** adding an export sink leaves the compiled program's **op count and output field bit-identical** — controls: the same subtree wired into a *non-terminal* node does change the op count (so the criterion measures terminality, not an empty graph), and `has_output()` is asserted false so a sink can never become a preview root; **[A2]** `GraphAllNodeSocketsGate`, `GraphNodeEditorUIGate` and `GraphPaletteAndConstantsGate` still pass with the sinks registered — the registry sweeps assert every node is evaluable and a terminal sink is not (§10); **[B]** no file is written by `evaluate()` or by a preview refresh — asserted on the file's absence across a parameter sweep — control: the explicit export writes it; **[C]** a png16 round-trip reproduces the field within quantisation using the sidecar range — control: png8 does not, so the criterion measures bit depth and not the writer; **[D]** `Export All` writes one file per sink, is cancellable, and the report names them — control: cancelling half way leaves the remainder **unwritten** and says so; **[E]** the tap reads the sink's INPUT slot — control: muting the upstream node changes the file. |
| **V7a** | **B3 publish + staleness** (§9.3): `Path Publish`, `Water Surface Publish` **closed-loop half** (a closed PATH becomes a `Pasture3DPool`'s outline; the pool stays flat), the digest on both sides, the stale warning, and the "a stale consumer still answers" rule. Touches no runtime query path. Closes most of `PASTURE3D_SPLINE_GRAPH_SPEC.md` §12.3. | `GraphRuntimeSinkGate`: **[A]** a graph-published path reaches `Pasture3DRoadRuntime.locate()` — control: without the publish, `locate()` reports off-road at the same world point; **[B]** editing the terrain under a published water surface marks the consumer stale — control: an unrelated edit elsewhere does not; **[C]** the digest asserted is the **consumer's stored** one, not the producer's (`check-derived-values-outside-the-chain`) — control: a republish with unchanged content leaves the stored digest equal, so the criterion is not merely observing that hashing is deterministic; **[D]** a stale consumer still answers and reports `stale` — control: a fresh one answers and reports fresh; **[E]** a **closed** published path builds a `Pasture3DPool` outline and an **open** one does not — control: the open path is routed to a Stream instead and the Pool's existing "this curve is not closed" warning still fires, so the discriminant is `closed` and not the node's wiring; **[F]** a Pool fed a published loop is still **flat** — assert `_still_surface_y` returns one value across the whole outline — control: the V7b stream fixture does not. |
| **V7b** | **Sloped water surfaces** (§9.4): the open-path half of `Water Surface Publish`. A published PATH's heights fill `Pasture3DStream`'s row Y and its per-vertex half-widths fill `_ribbon_half_l` / `_ribbon_half_r`, replacing `_apply_bank_surface`'s inputs; **`_bank_crest`, `_waterline_half`, `_effective_bank_search` and their exports are deleted** (§9.4.3), leaving published-rows → `fill_offset`. Ships the **preset graph** `Add Water` wires, plus migration for existing streams. Nothing downstream of the three arrays changes. Last phase in the document: it is the only one that modifies a shipped per-physics-tick path. | `GraphWaterSlopeGate`: **[A]** **the preset graph reproduces the deleted bank measurement** on a fixture, compared against the old code captured *before* removal — controls: the fixture's two banks must differ in height (or "lower crest wins" is untested), and a deliberately wrong preset must fail, since this criterion exists to catch a silent downgrade rather than a crash; **[B]** a published sloped surface and the water shader agree **within Phase 7 criterion D's existing 0.009 m**, on that gate's 400 kg boat fixture — controls: the same criterion still passes on an unmodified stream, and the fixture's level varies by metres end to end so a flat surface cannot agree trivially; **[C]** `_contains_local` follows the **published** half-widths — assert a point inside the published envelope and outside `ribbon_half_width` is in the water — control: a constant-width publish puts the same point out; **[D]** `_still_surface_y` reads baked rows and evaluates no graph — assert the graph's evaluation count is unchanged across a physics tick with buoys active — control: a bake does increment it; **[E]** `get_water_height`'s per-frame memo still serves a repeat query — counted, since `Pasture3DBuoy` asks twice per tick and the memo is what makes that affordable — control: a query at a different XZ misses; **[F]** a stream with **no terrain** still falls back to `c.y + fill_offset` — control: the same stream with terrain does not, so the surviving tier is measured and not merely present; **[G]** an unmigrated legacy stream **warns** rather than silently dropping to `fill_offset` (§9.4.3) — control: a migrated one does not warn. |

**Critical path for the stated goal is V1 → V3.** V1 fixes the four-causes-of-black and the silent bail,
which are what make the current previews untrustworthy; V3 is the one thing the author explicitly cannot do
today. **V3 has no dependency on V1 or V2 and can be brought forward** if the spline work is hotter than the
thumbnail work — its only prerequisite, `derived_path()`, is already built.

V2 before V4, because the inspector's value is mostly on solver channels — and V4 re-taps at its own
resolution, so a channel it cannot address is a panel showing the wrong field at higher fidelity.

V5, V6 and V7a are independent of each other and of (A) entirely. V6 is the cheapest of the three. V7a
closes an already-written spec's open item. **V7b comes last of all**: it is the only phase in this document
that modifies a shipped runtime query path, and separating it is what keeps a water regression from
arriving attached to a road publish.

---

## 12. Decisions

> **Read first:** nothing new — every decision below names the section it belongs to, and that section's
> "Read first" block is the reading list. `PASTURE3D_SPLINE_GRAPH_SPEC.md` §11 and
> `PASTURE3D_SIM_NODE_SPEC.md` §19.9 are the house precedents for how a decision and a departure are
> recorded, if you are adding to either.

Each of these had a live alternative. Recorded so they are argued once.

### 12.1 Extend the existing preview; do not rebuild it — §3, §4
Rejected: a new preview subsystem. The brief required saying explicitly what is wrong with the current one
before proposing anything, and the honest answer is **five local defects, none structural**. The
architecture — editor-owned, opt-in per node, one compile and one tap pass off-thread, token-guarded apply,
`evaluate()` untouched — is right, and is better than Hesiod's (which builds a `DataPreview` for every node
unconditionally, §2.1 Q2). Every defect in §4 is fixed by V1 and V2 without moving a file.

### 12.2 Three surfaces, not one — §5.1
Rejected: making the thumbnail better and stopping. A 128 px image cannot carry an axis, a probe readout or
a legend, and the tools that tried all ended up adding a panel anyway. Rejected also: replacing the
thumbnail with the inspector. Scanning a chain of six nodes at a glance is a different task from reading
one, and the inspector shows one node.

### 12.3 Representation comes from the port **type**, never the port name — §5.3
Rejected: Hesiod's `wild_guess_view_param.cpp`, which reads names and category substrings as an API
(`cat.find("Selector")`, an exclusion list containing `"mask"`). It is a guess and it is spelled like one.
`output_port_types()` already exists and already returns the answer. A rename must never change a picture.

### 12.4 MASK is absolute; HEIGHT is auto, labelled and lockable — §5.2
Rejected: **always absolute**, which makes a 4 m dune invisible next to a 400 m massif, and terrain has no
canonical range. Rejected: **always auto**, which is today's behaviour and is §4.2 — a mask that scales to
its own extremes is a false statement, and a self-rescaling height view hides the parameter being adjusted.
The split follows from what the type *means*: a mask has a defined range and a height does not. The chip
and the lock are what make AUTO honest rather than merely convenient.

### 12.5 A PATH draws geometry; it never renders its grid — §6.1
Rejected: leaving the black thumbnail and documenting it. The grid slot of a PATH node is zeros by
construction and rendering it produces an image indistinguishable from three unrelated failures (§4.3).
Hesiod reaches the same conclusion for `hmap::Path` and it is the part of its preview code worth copying.

### 12.6 `preview_on` and every view flag stay out of the graph revision — §6.4, §5.2 Rule 3
Rejected: giving `preview_on` an emitting setter, which `gdscript-export-emits-no-changed` and
`PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §11 item 2 would otherwise both recommend. Those are about values that
**invalidate a cache**; a view flag is the standing exception, and **the precedent is already in the guide
with a gate on it** — §8: *"`graph_position` deliberately emits no `changed`. Dragging a node is a reason to
re-save the layout, not to re-bake the terrain. `GraphEditModelGate [E]`'s control asserts exactly this."*
Emitting `changed` from `preview_on` would bump the revision, re-bake the terrain, and destroy the "instant
show/hide, not a re-evaluate" property the brief requires preserving. The same applies to the range lock
and the chosen representation, and V1 [G] / V3 [F] are the `GraphEditModelGate [E]` of this document.
`graph_editor.gd:127` already excludes `preview_on` from the canvas hash for the same reason.

### 12.7 Export sinks are terminal; there is no `auto_export` — §9.2
Rejected: Hesiod's flag, its button that flips and restores it, and its JSON pre-pass that rewrites it for
batch runs. Three mechanisms for one problem our compiler does not have — a node nothing can wire *from* is
never an ancestor of a root, so the compiler never visits it. Rejected also: modelling the sink on **mute**,
which was the first idea and is wrong: a muted node is not rewired out, it lowers to op 12 `output`, a
passthrough (`pasture3d_terrain_graph.gd:1304`). Mute costs an op; terminality costs nothing.
`Pasture3DGraphNodeOutput` already carries the pattern and already calls itself a sink. The write lives in
an entry point the evaluator cannot call, which is a stronger guarantee than a boolean anyone can set — and
it means adding an export node cannot cost the graph its native route, which matters because a graph-wide
bail is silent.

### 12.8 B1 belongs to the bake system; it is not an export — §9.1
Rejected: a `Control Map Export` node writing through a new path. The bake system already owns write-area
clipping, layer binding, undo, per-layer-owner clearing and staleness, and a parallel writer would have to
reimplement all five and would get at least one wrong. `bake_all_brushes()` (`pasture3d_sim_manager.gd:1525`)
already walks layer owners; a channel sink is a thing that happens inside a bake, not beside it.

### 12.9 NONE is a zero mask, not a sentinel index — §9.1
Rejected: reserving index 31, or spending a free bit on a validity flag. Terrain3D allows 32 textures and
all 32 indices are legal, so 31 is not spare; a validity bit would diverge from the Terrain3D control-map
layout and make every imported map read as invalid. Scoping the write with a mask needs no bits, cannot be
misread as an index, and is how every other write in the plugin already works.

### 12.10 No biome index in the control word — §9.1
Rejected: spending bits 3–6 on a 16-value biome field. Sixteen is a toy budget, and anything stored there
**cannot blend** — `blend(8)` interpolates base against overlay, and a raw index field would hard-edge at
every boundary, which is the artifact the base/overlay/blend split exists to prevent. A biome is a derived
read of `(base, overlay, blend)` and the graph's own masks. **All four bits stay reserved** — see §12.15,
which withdraws the `graph_owned` bit an earlier draft spent at 6.

### 12.15 No `graph_owned` bit; if provenance is ever needed it is an owner-id mask — §9.1, §14.2 item 3
**Settled 2026-09-06.** V5 spends none of the four free bits. Three reasons, in the order they decide it.

*No consumer.* The bit could only serve a reader of the composited control map, because the composite is
where per-layer `owner_id` stops existing. Both such readers (`pasture3d_splat.gd:199`,
`pasture3d_road_brush.gd:1593`) read to preserve, not to arbitrate.

*Unreclaimable.* A spent bit is baked into `.res` files, so unspending it is a data migration — and bits
3–6 are the only expansion room in a word §12.9/§12.10 pin to Terrain3D compatibility. If Terrain3D ever
defines bit 6, a bit we took becomes an interop break.

*A boolean is the wrong shape anyway — and this is the decisive reason, because it kills the bit even if a
consumer appeared.* The bug the bit was proposed for,
`road-batter-overwrites-other-roads`, was one road's batter sweeping over another road's carriageway with
the second bake winning by scene order. **Both writers were tool writers.** `graph_owned` would have been
set on both and distinguished nothing. What actually fixed it was a grid-shaped `protect` mask
(`Pasture3DRoadBrush._foreign_formation_mask`) carrying *whose* formation, used to **refuse** the batter
branch rather than to rank it. `junction-trim-is-two-consumers` is the same shape — two consumers of one
rule, not unknown provenance. (`road-tier-far-paint-built`, where `-1` silently meant texture 31, is a
validation bug that gate [C] covers; provenance is irrelevant to it.)

**So the sanctioned answer, recorded here so the bit is not re-proposed:** if provenance is ever genuinely
needed, build a grid-shaped **owner-id mask** in the shape of `_foreign_formation_mask`, and use it to
refuse rather than to prioritise. One bit answers "did *somebody* write this", which is never the question;
the question is always "did *this other owner* write this", and one bit cannot answer it.

### 12.16 A brush layer is never hand-painted; touch-ups go on a layer above it — §9.1, V5 [D]
**Settled 2026-09-06, and it is the user's existing rule rather than a new one.** A graph sink's layer is
`reserved`, and a reserved layer **refuses strokes** — enforced in C++ at `src/pasture_3d_editor.cpp:1049`
(`is_locked() || is_reserved()` → `_stroke_blocked`, `BLOCK_LOCKED`) and surfaced in the dock at
`layers_dock.gd:166` ("Layer '%s' is locked or reserved — stroke blocked").

So the conflict this spec kept trying to arbitrate **does not arise**: the graph always wins on its own
layer, unconditionally, because nothing else can write there. A user who wants a touch-up creates their own
layer *above* the sink's, where topmost-covered-wins gives it to them and no re-bake can reach it. Both
properties are guaranteed by construction rather than by policy, which is why this is better than either
ordering rule — neither "hand paint wins" nor "graph wins" leaves the other party a silent failure mode.

> **This is why §9.1a exists.** The rule is built for HEIGHT and **not** for control or colour, which is
> every V5 sink.

### 12.11 The 3D preview is the real terrain, and that stays — §2.3
Every comparable tool previews on a proxy mesh and builds the real thing separately. We paint actual
terrain, at full resolution, because isolating an area and doing the work at full res is the point of the
brush system. Rejected: a proxy preview surface. The cost is that a large brush is slow to preview, and
§5.4's opt-in downscale is the answer to that — **opt-in, badged, and preview-only** — rather than a second
rendering path with its own fidelity gap to explain.

---

### 12.12 A published water surface is a PATH, not a level field — §9.3, §14.1b Q5
Rejected: a level *grid*, which would generalise to deltas, braided channels and wind-tilted lakes. It also
needs a new mesh builder, a new physics-tick query, and a storage decision — and it breaks the property
§9.4.1 identifies as the one that matters, that the mesh and the CPU query read **one** source. A PATH is
already that source: `_ribbon_rows` is a row array, and both readers already exist. The closed/open split
falls out for free because `Pasture3DPool` and `Pasture3DStream` already split on `curve.closed`.

### 12.13 The bank measurement is deleted rather than kept as a fallback — §9.4.3
Rejected: keeping `_bank_crest` as a middle tier under the published rows. Per `pre-stack-code-gets-deleted`
superseded code comes out, and a three-tier fallback is how a river ends up with a waterline nobody can
account for — the tier that answered is invisible at the point you are looking at the water. The cost is
that the preset graph must actually reproduce the measurement, which §14.2 item 2 records as this phase's
live risk and gate [A] forces to be answered **before** the deletion.

### 12.14 A pool receives an extent and stays flat — §9.3, V7a [F]
Rejected: giving still water a sloped surface for symmetry with the stream. Still water is level; that is
what makes it still. Keeping the pool flat also keeps the pond half of the publish out of V7b entirely —
it touches no runtime query path, so it ships in V7a where a mistake cannot reach a buoy.

---

## 13. What I am deliberately not building

- **A thumbnail on every node.** Hesiod does this and pays for it on every evaluation of every graph. Ours
  is opt-in and stays opt-in.
- **A proxy 3D preview surface.** §12.11.
- **A colour-ramp editor.** The taxonomy in §5.3 is six ramps chosen once. A ramp editor is a week and
  answers a question nobody has asked.
- **`SLOPE_ELEVATION_HEATMAP`.** Hesiod shipped it commented out; the 2D scatter of slope against elevation
  is a geomorphology diagnostic, not an authoring tool, and V4's histogram covers the case people actually
  hit.
- **Tiled export.** Hesiod's `ExportTiled` with its `overlapping_edges`, `reverse_tile_y_indexing` and
  `leading_zeros` is a pipeline adaptor for someone else's importer. `Pasture3DData::export_image` already
  has `EXPORT_SLICED` and `EXPORT_PER_REGION` for our own data.
- **`Import*` nodes.** Hesiod pairs every export with an import. The graph already reads terrain through
  the input; a file-reading source node is a different document.
- **A biome map.** §12.10.
- **A level-field water surface.** §12.12 — the PATH is the published shape. Deltas, braided channels and
  wind-tilted lakes are the case a grid would buy, and none of them is asking yet.
- **Animation, turntables, or exporting a preview image.** A debug view is throwaway by definition
  (§1), and anything worth saving is (B).
- **Changing the base/overlay/blend packing.** The review in §9.1 concluded the layout is sound and the
  problems attributed to it (the `-1` bug) were not layout problems. Compatibility with Terrain3D-derived
  data is worth more than four bits.
- **A second export path.** V6 goes through `Pasture3DData::export_image`'s writers where the shapes line
  up (§12.8's reasoning, applied to files).

---

## 14. Open

### 14.1 Settled 2026-09-06

Four questions were open when this document was first written. All four are answered and the answers are
folded into the sections above; they are recorded here so the reasoning is not lost.

| # | Question | Answer | Where |
| :-- | :--- | :--- | :--- |
| 1 | Inspector resolution: re-tap, or upsample the thumbnail? | **Re-tap at inspector resolution.** An upsampled probe and a histogram binning 16 k samples of a million cells are quantitatively wrong while looking quantitative. **Cost measured 2026-09-06 (§14.2 item 1): 512 px is 8–33 ms, ≤27% of the 120 ms debounce, and tap count is free — ship the live re-tap; the *sample*-button fallback stays documented but unbuilt** | §7, V4 [A2]/[A3] |
| 2 | Where view state lives when two brushes share a graph | **On the resource, beside `preview_on`** — and the open-graph gesture binds the selected brush as the preview source for **every graph in its modifier stack**, so §4.6's scene-order fallback stops being reachable | §5.6, §4.6, V1 [H] |
| 3 | `Export Normal Map`: derive, or take a normal input? | **Both** — derive by default, declare the optional VECTOR port now so the node's shape is final. The port **refuses with a warning** until the program can carry a vector grid; it never silently falls back | §9.2 |
| 4 | How much sloped water V7 attempts | **Sloped surfaces are in scope**, and the risk was overstated in the asking: `_still_surface_y` is already a virtual taking world XZ, already overridden by `Pasture3DStream`. Split out as **V7b** because it touches a per-physics-tick path | §9.4, V7b |

### 14.1b V7b settled 2026-09-06

Four more, asked once §9.4 showed the seam already existed.

| # | Question | Answer | Where |
| :-- | :--- | :--- | :--- |
| 5 | What the graph publishes as a surface | **A PATH.** Closed loops go to a `Pasture3DPool` as an outline — the input its `source_spline` already takes — and open paths with heights become a `Pasture3DStream`'s rows. `Pasture3DGraphPath.closed` is the discriminant and both bodies already split on it | §9.3, §9.4.1 |
| 6 | Relation to `Pasture3DStream`'s own bank measurement | **The graph replaces it entirely.** `_bank_crest`, `_waterline_half`, `_effective_bank_search` are deleted per `pre-stack-code-gets-deleted`; a preset graph ships with `Add Water` and existing streams migrate onto it. Two tiers remain: published rows, then `fill_offset` | §9.4.3 |
| 7 | How the runtime decides where the water is | **The published width envelope**, and it costs nothing: `_contains_local` is already `_ribbon_surface_at(...)[0]`, which already consults the asymmetric per-row `_ribbon_half_l` / `_ribbon_half_r`. The graph fills arrays that exist | §9.4.2 |
| 8 | Rivers only, or lakes too | **Sloped surfaces are rivers only.** A pool receives a graph-published *extent* and stays flat, which is physically right for still water — so the pond half carries no parity risk and lands in **V7a**, not V7b | §9.3, V7a [F] |

> **One correction folded in.** An earlier draft asked whether the shader should read the level by
> transcription or by sampler. Neither: `water_surface.gdshaderinc` displaces from `VERTEX` and has no
> level uniform at all. The level is in the mesh, parity is structural, and §9.4.1 is the corrected
> account.

### 14.2 Still open

1. ~~**What the inspector's second tap actually costs.**~~ **Measured 2026-09-06** —
   `project/bench/GraphInspectTapCostProbe.gd`, debug build (the binary the editor loads), three runs,
   15 timed repeats after 3 discarded warm-ups, 512 m rect. Medians in ms:

   | fixture (ops) | 128 | 192 | 256 | 384 | 512 | 512 vs 128 |
   |---|---|---|---|---|---|---|
   | LIGHT (4) | 2.09 / 2.26 / 2.27 | 3.11 / 3.21 / 3.34 | 3.54 / 3.72 / 4.01 | 5.33 / 5.74 / 7.86 | 8.25 / 9.32 / 11.27 | 3.9–5.0× |
   | MEDIUM (6) | 3.01 / 3.15 / 3.16 | 4.32 / 5.03 / 5.01 | 5.88 / 5.96 / 6.40 | 10.11 / 10.46 / 12.25 | 17.30 / 18.53 / 21.36 | 5.8–6.8× |
   | HEAVY (8) | 7.39 / 7.43 / 7.68 | 10.50 / 10.67 / 11.36 | 12.25 / 12.59 / 13.11 | 17.87 / 18.75 / 20.94 | 32.83 / 32.48 / 32.74 | 4.3–4.4× |

   Three findings, in the order they bear on the design.

   **(a) Tap count is free; resolution is the cost.** At 256 px on HEAVY, 1 / 2 / 4 / 8 taps measured
   14.26 / 14.32 / 13.82 / 14.47 ms — flat inside noise, and the 4-tap figure is *below* the 1-tap one,
   which is what "no signal" looks like. The expense is evaluating the program, not copying slots out of
   it. This is the number §8 and §12.3 were asserting without evidence, and it is what makes the
   re-tap decision (§14.1 Q1) cost only what the extra cells cost — there is no per-tap tax to avoid by
   riding the thumbnail pass instead.

   **(b) Scaling is strongly sublinear, so the high resolutions are cheaper than they look.** 16× the
   cells costs 4–7× the time; ms/Mcell falls from 139–469 at 128 px to 43–125 at 512 px. A large fixed
   per-call cost dominates at thumbnail resolution, which means the 128 px thumbnail pass is a poor
   predictor of what a bigger tap costs — multiply-by-area estimates overstate it by 3–4×.

   **(c) 512 px fits the debounce with room to spare.** `PREVIEW_DEBOUNCE_SEC = 0.12`
   (`graph_editor.gd:66`), and both passes run off the main thread. The worst case measured — HEAVY at
   512 px — is 32.7 ms, **27% of the debounce**. **The §7 fallback (a *sample* button instead of a live
   re-tap) is therefore not needed** and V4 should ship the live re-tap at 512 px. Keep the fallback
   documented rather than deleted: an author's real graph can exceed 8 ops, and the wrong response to
   that is upsampling, not a slower live probe.

   **Two caveats on these numbers.** They are a *debug* build — correct for the editor, wrong as an
   absolute ceiling. And per `ask-before-perf-tests` the machine is shared: the main tables reproduced
   across three runs within ∼1–13%, but a fourth block measured the same HEAVY@256 configuration at
   12.2 / 13.5 / 14.3 ms across the three runs — up to 17% apart from the main table's figure for the
   *same* configuration. Treat the ratios as the finding and the absolute ms as ±20%. The margin above
   is 4×, so the conclusion survives the noise; a conclusion that needed 10% precision would not.
2. **Whether the preset graph can actually reproduce the bank measurement.** §9.4.3 deletes
   `_bank_crest` / `_waterline_half` / `_effective_bank_search` and replaces them with a shipped preset
   graph. Nothing yet demonstrates that a graph *can* express "sample both banks outward to a search width
   derived from the host Trough, take the lower crest, subtract freeboard, smooth" — the outward search
   in particular is a lateral ray, not a field evaluation, and the graph's vocabulary is fields and paths.
   **This is V7b's first task and it is a real risk to the phase**: if the preset cannot match, the choice
   is between keeping the measurement (reversing §14.1 Q2) and accepting a different waterline. Gate
   criterion [A] exists to make that answer arrive before the deletion, not after.
3. ~~**Whether `graph_owned` is needed at all.**~~ **Settled 2026-09-06 — §12.15: no bit is spent, and an
   owner-id mask is the sanctioned answer if provenance is ever needed.** Grounded first: bits 3–6 have no
   accessor or shift anywhere in `src/`, and the two readers of the composited control map
   (`pasture3d_splat.gd:199`, `pasture3d_road_brush.gd:1593`) both read to preserve rather than to
   arbitrate. Settling it opened a **new and larger** item, now §9.1a and tracked as item 4 below.

4. **Whether hand control/colour paint is already being erased on terrains that carry a road.** Opened by
   §9.1a, which V5 must fix for its own sinks regardless. The narrower question is whether the same path is
   live *today*: the road connector creates a control layer, which makes
   `has_overlay_of_type(TYPE_CONTROL)` true, after which `composite_region` recomputes control from a
   Control Base snapshotted at the moment that layer was created — so hand texture paint made afterwards
   would be erased the next time anything composites those cells. **Read, not reproduced.** One gate
   answers it: hand-paint control on a terrain with a road, composite that rect, compare. If it
   reproduces, it is its own fix with its own gate, **ahead of V5 and outside this spec** — V5 would
   otherwise inherit a live bug and get the blame for it.
