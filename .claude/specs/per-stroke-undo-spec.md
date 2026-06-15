# Implementation Spec: Per-Stroke Undo/Redo for Layered Sculpting & Painting

Status: Draft (spec only — no code changed)
Author: investigation pass, 2026-06-14
Scope: Pasture3D (Terrain3D fork, Godot 4.6 GDExtension). Non-destructive layers system.

---

## 1. Problem statement

### Current behavior
When the user sculpts/paints terrain while a non-destructive **layer** is the active
target, pressing **Undo** does not cleanly revert the last brush stroke. In practice the
*layer* is left in a corrupted / "cleared" state: the visible composite snaps back, but the
layer **source** tiles are not restored, so the next recomposite (opacity/visibility/blend
change, add/remove/move layer, road-connector refresh, save→reload) re-derives the region
from a stale layer source and the layer appears wiped or the un-done stroke reappears.

### Desired behavior
Undo and Redo operate on **individual strokes**. A stroke = one continuous brush operation
from mouse-down (`start_operation`) to mouse-up (`stop_operation`). Undo must revert exactly
that one stroke — restoring both the **layer source tiles** and the **composited region
image** for the touched region(s) to their pre-stroke state — and Redo must re-apply exactly
that stroke. This must hold for sculpting (height layers) and painting (control/color
layers), and must leave all *other* strokes/layers untouched.

---

## 2. How the system works today (grounded references)

### 2.1 Layer storage
- `Pasture3DLayer` (`src/pasture_3d_layer.h` / `.cpp`) is a `Resource` holding sparse tiles:
  `Dictionary _tiles` keyed `region_loc(Vector2i) -> Dictionary{ tile_coord(Vector2i) -> Image }`.
  See `_get_tile_ptr` `src/pasture_3d_layer.cpp:10-19` and `_get_or_create_tile` `:28-39`.
- Tile format follows map type (`_overlay_format` `src/pasture_3d_layer.cpp:24-26`): height/control
  overlays = `FORMAT_RGF` (R=value, G=weight); color overlays = `FORMAT_RGBA8` (RGB albedo,
  A=weight). The dense **Base** tile aliases or owns the region map (`set_region_image` `:250-261`).
- Sub-tiling: non-Base layers default `_tile_size = 64` (`clear()` `src/pasture_3d_layer.cpp:54`),
  region default is 256, so one region holds a grid of small tiles. The Base uses
  `tile_size = region_size` (`_synthesize_base_layer` `src/pasture_3d_data.cpp:45`).
- `Pasture3DLayerStack` (`src/pasture_3d_layer_stack.*`) is the ordered list; Base pinned at
  index 0; has active-layer index.
- `Pasture3DData` owns `Ref<Pasture3DLayerStack> _layer_stack`. Routing is on only when
  `is_layer_routing()` (stack valid AND `layer_count > 1`).

### 2.2 Where a stroke is applied / committed
- Stroke lifecycle is driven from `project/addons/pasture_3d/src/editor_plugin.gd`:
  mouse-down → `editor.start_operation` (`editor_plugin.gd:267`), drag →
  `editor.operate` (`:234`, `:268`), mouse-up → `editor.stop_operation` (`:273`).
- `Pasture3DEditor::start_operation` (`src/pasture_3d_editor.cpp:983-1019`) decides routing
  for the stroke and captures the active **height** layer into `_stroke_layer`
  (`:1005-1018`). A locked/reserved active layer sets `_stroke_blocked` and the stroke is
  swallowed. NOTE: only `TYPE_HEIGHT` active layers are captured (`:1010`); control/color
  active layers fall through to the legacy destructive region-map write.
- `Pasture3DEditor::_operate_map` (`src/pasture_3d_editor.cpp:88-613`) computes the brush
  result per pixel. When `route_to_layer` (`:108`) is set, it writes into the layer instead
  of the region map: `_backup_layer_tile(region_loc)` (`:565`), then
  `_stroke_layer->set_sample(region_loc, map_pixel_position, dest.r, 1.f)` (`:566`), tracking
  the dirty rect per region in `_stroke_dirty` (`:567-571`). After the pixel loop it
  recomposites the touched rects: `data->composite_region(loc, dirty_rect, false)`
  (`:580-585`), then `update_maps(...)` uploads to GPU (`:595-600`).
- `composite_region` (`src/pasture_3d_data.cpp:1035-1077`) walks the stack bottom→top and
  writes the region image (height pass `_composite_height_region` `:1082+`, plus control/color
  passes when overlays exist). The region image is a *derived* artifact; the layer source is
  the truth.

### 2.3 How undo/redo is wired
- C++ side builds two `Dictionary` payloads in `Pasture3DEditor::_store_undo`
  (`src/pasture_3d_editor.cpp:632-711`) and registers them through the plugin:
  - `create_undo_action` (`editor_plugin.gd:503-504`) →
    `EditorUndoRedoManager.create_action(name, MERGE_DISABLE, terrain)`.
  - `add_undo_method` / `add_do_method` (`editor_plugin.gd:507-516`) forward to the
    `EditorUndoRedoManager`; both bind `Callable(this, "apply_undo")` with the payload.
  - `commit_action(false)` (`editor_plugin.gd:519-520`) — `false` = do-method NOT executed
    on commit.
- `Pasture3DEditor::_apply_undo` (`src/pasture_3d_editor.cpp:713-813`) is the single method
  used for **both** undo and redo. It:
  1. restores layer source tiles from `p_data["layer_tiles"]` via
     `layer->restore_region_tiles(loc, tiles[loc])` (`:721-731`);
  2. restores the composited region images from `p_data["edited_regions"]` (`:733-753`);
  3. handles added/removed regions + region_locations (`:760-792`);
  4. calls `update_maps(...)` (`:794-798`) and `refresh_base_alias()` (`:812`).
  Notably it does **not** call `composite_region` — it relies on the stored region-image
  snapshot being the correct composite.
- Snapshot capture:
  - Region (composite) snapshots: `backup_region` (`src/pasture_3d_editor.cpp:1053-1069`)
    deep-copies the region (`region->duplicate(true)`, deep — `src/pasture_3d_region.cpp:373-396`)
    on first touch into `_original_regions`; redo copies are made in `stop_operation`
    (`:1078-1090`).
  - Layer-tile snapshots: `_backup_layer_tile` (`:617-622`) deep-copies the **whole region's
    tile dict** the first time the stroke touches that region into `_layer_undo_tiles`; the
    post-stroke (redo) snapshot is taken in `stop_operation` (`:1092-1097`) into
    `_layer_redo_tiles`. Both use `Pasture3DLayer::duplicate_region_tiles` (`:199-211`) which
    deep-copies each `Image` (`_dup_image` `:192-197`).
- `restore_region_tiles` (`src/pasture_3d_layer.cpp:213-227`): if the snapshot dict is
  **empty**, it **erases the whole region** from `_tiles`; otherwise it replaces that region's
  tile dict with deep copies. This is correct *as a primitive* — an empty snapshot means
  "this region had no tiles before the stroke."

---

## 3. Root cause analysis

The per-stroke design is sound, but a **shallow-copy aliasing bug** corrupts the layer-tile
payloads stored in the undo manager. Three lines interact:

1. `src/pasture_3d_editor.cpp:702`
   ```cpp
   _terrain->get_plugin()->call("add_undo_method",
       Callable(this, "apply_undo").bind(_undo_data.duplicate()));
   ```
   `Dictionary::duplicate()` defaults to **non-recursive (shallow)**. The new top-level dict
   shares its *values* with the originals. So the stored undo payload's
   `["layer_tiles"]["tiles"]` is the **same Dictionary instance** as the editor member
   `_layer_undo_tiles` (assigned at `:685`).

2. `src/pasture_3d_editor.cpp:706`
   ```cpp
   _terrain->get_plugin()->call("add_do_method",
       Callable(this, "apply_undo").bind(redo_data));   // no duplicate at all
   ```
   The redo payload's `["layer_tiles"]["tiles"]` is the **same instance** as
   `_layer_redo_tiles` (assigned at `:689`).

3. `src/pasture_3d_editor.cpp:1105-1106` (inside `stop_operation`, which runs *after*
   `_store_undo` returns):
   ```cpp
   _layer_undo_tiles.clear();
   _layer_redo_tiles.clear();
   ```
   Because of (1) and (2), these `clear()` calls **empty the very dictionaries that the
   committed undo and redo actions still reference.**

Net effect: by the time the action is committed, both the undo and redo payloads carry an
**empty** `layer_tiles.tiles`. When the user later triggers undo/redo, `_apply_undo`'s layer
loop (`:726-730`) iterates zero keys and **restores nothing to the layer source**. Only the
region *composite* image is restored (its snapshots are isolated — `_original_regions` is
*reassigned* not cleared at `:1101`, and region copies are deep). This produces a **desync**:
the visible region image is reverted, but the layer source still contains the stroke.

The user-visible "clears the entire layer" symptom is the downstream consequence of this
desync. Any later `composite_region` over the touched region — opacity/visibility/blend
change (`layers_dock.gd` → `recomposite_layer`), add/remove/move layer
(`pasture_3d_data.cpp:149-189`), the road connector refresh, or save→reload — re-derives the
region from the still-modified (or, after an erase path, half-modified) layer source. Under
REPLACE-mode hand-sculpt layers this manifests as the layer content snapping to a wrong/empty
state rather than a clean single-stroke revert.

> Secondary aliasing risk (same class of bug): `_undo_data["edited_regions"] = _original_regions`
> (`:642`) stores the array by reference; `stop_operation` happens to *reassign* the member
> (`:1101`) rather than `clear()` it, so this particular array survives — but it is fragile and
> should be hardened by the same deep-snapshot discipline (see §4 step 4).

The existing unit test `test_layer_undo_restore` (`src/unit_testing.cpp:491-527`) passes
because it exercises only the `Pasture3DLayer` snapshot/restore **primitive** in isolation —
it never goes through `_store_undo` / `stop_operation`, so it cannot catch the shallow-copy +
`clear()` aliasing defect. This is the test-coverage gap that let the bug ship.

---

## 4. Proposed solution / design

### Recommended approach (primary): deep-isolate the snapshot payloads at commit time

Keep the existing architecture (snapshot pre-stroke layer tiles + region composite on
mouse-down/first-touch; snapshot post-stroke on mouse-up; one `EditorUndoRedoManager` action
per stroke; single `apply_undo` used for both directions). The only thing wrong is that the
payloads alias mutable editor members. Fix by ensuring every payload handed to the undo
manager owns **independent deep copies** of its tile dictionaries, so the post-stroke
`clear()` in `stop_operation` cannot reach into committed history.

Why this approach:
- Minimal, surgical, and matches the design already documented in
  `PASTURE3D_LAYERS_GUIDE.md` §6 (snapshot active layer's touched tiles + recomposited
  region images in the same action).
- The snapshots are already small and sparse (only touched regions' tiles), so a deep copy at
  commit is cheap and bounded by the stroke's footprint — not the whole layer.
- No change to the load/save format, the compositor, or the editor stroke loop.

Concretely, the snapshot dictionaries must be **detached** before the members are cleared. Two
equivalent options — pick (A):

- **(A) Move-and-clear-local (preferred).** In `_store_undo`, build the `tiles` payloads from
  *fresh* dictionaries that are not the persistent members, e.g. copy
  `_layer_undo_tiles`/`_layer_redo_tiles` into local dictionaries with a **deep** per-region
  duplicate, store those locals in the payload, and never reference the members again. Then the
  `clear()` in `stop_operation` is harmless. (A helper that deep-clones a
  `region_loc -> {tile_coord -> Image}` map — re-using `_dup_image` semantics — keeps this DRY.)
- **(B) Stop clearing shared state / null the members.** Instead of `_layer_undo_tiles.clear()`
  / `_layer_redo_tiles.clear()` in `stop_operation`, reassign the members to brand-new empty
  `Dictionary()` instances (mirroring how `_original_regions`/`_edited_regions` are reassigned
  at `:1101-1102`). This breaks the aliasing without an extra deep copy — BUT it still leaves
  the committed payload sharing the *Image* objects with whatever the layer holds; since
  `duplicate_region_tiles` already deep-copied the Images into the snapshot, this is actually
  safe for tiles. (A) is still preferred because it is robust against future inner-mutation and
  is symmetric with the region path.

Additionally, **also fix line 706** so the redo payload is deep-isolated the same way the undo
payload is (today it is passed with no duplication at all).

### Alternatives considered (not recommended)
- **Per-region dirty diff instead of full-tile snapshots.** Store only changed pixels. More
  memory-efficient for huge strokes but adds significant complexity (sub-tile pixel diff,
  redo reconstruction) for little gain — tiles are already 64×64 and sparse. Reject for v1.
- **Recompose-on-undo instead of restoring region images.** Have `_apply_undo` restore only
  the layer source and then call `composite_region` for each touched region instead of storing
  region snapshots. This *halves* the payload (no region images) and structurally guarantees
  composite==source after undo. Attractive, but: (a) it changes behavior for the legacy
  non-routed path that still relies on region snapshots; (b) control/color "topmost-covered-
  wins" / alpha-over passes must be re-validated; (c) larger change surface. Recommend as a
  **follow-up optimization**, not the bug fix. The minimal fix in §4(A) restores correct
  behavior immediately.

---

## 5. Detailed implementation steps (ordered)

All changes are in `src/pasture_3d_editor.cpp` unless noted. No format/serialization changes.

1. **Add a deep-clone helper for a region→tiles snapshot map.** Add a small private helper
   (or reuse `Pasture3DLayer::duplicate_region_tiles` per region) that, given a
   `Dictionary{ region_loc -> Dictionary{ tile_coord -> Image } }`, returns a new dictionary
   whose every nested `Image` is a fresh deep copy. The layer already exposes
   `duplicate_region_tiles(loc)` (`src/pasture_3d_layer.cpp:199-211`) which deep-copies a single
   region's tiles via `_dup_image` — iterate the snapshot's region keys and rebuild.

2. **Build isolated payloads in `_store_undo`** (`src/pasture_3d_editor.cpp:679-691`). Replace
   the direct assignments
   `undo_snap["tiles"] = _layer_undo_tiles;` and `redo_snap["tiles"] = _layer_redo_tiles;`
   with deep clones produced by step 1, so the payloads no longer alias the editor members.

3. **Deep-isolate both action payloads at registration** (`:702`, `:706`). Either rely on
   step 2 (cleanest) or, belt-and-suspenders, deep-duplicate the whole payload before handing
   it over. At minimum, make line 706 consistent with 702 (the redo payload must be isolated
   too). After step 2, the shallow `_undo_data.duplicate()` is acceptable for the tile sub-dict
   because the inner dict is now a private clone — but prefer passing already-isolated dicts.

4. **Harden the member-clear in `stop_operation`** (`:1100-1107`). With the payloads isolated,
   the existing `_layer_undo_tiles.clear()` / `_layer_redo_tiles.clear()` become harmless.
   Optionally switch them to reassignment (`_layer_undo_tiles = Dictionary();`) to match the
   `_original_regions`/`_edited_regions` reassignment style at `:1101-1102` and avoid any future
   aliasing surprises.

5. **(Optional, control/color parity)** Today `start_operation` only captures a HEIGHT active
   layer as `_stroke_layer` (`:1010`); control/color active layers fall through to the
   destructive legacy region write, so painting on a control/color *layer* is not routed and
   not per-stroke-undoable into the layer source. If painting-into-layer is in scope for this
   fix, extend `start_operation` to also capture control/color active layers and route
   `_operate_map`'s control/color writes through `set_sample`/`set_sample_color` + per-region
   composite (mirroring the height path). The undo machinery from steps 1–4 is map-type
   agnostic (`duplicate_region_tiles`/`restore_region_tiles` handle RGF and RGBA8), so no extra
   undo work is needed. If out of scope, document that layer painting routing is height-only
   and leave control/color as destructive-with-region-undo for now.

6. **Add an integration test** (see §7) that exercises the full `_store_undo` →
   `stop_operation` → `apply_undo` path, not just the layer primitive.

---

## 6. Edge cases

- **Stroke spanning multiple regions.** `_stroke_dirty` and `_layer_undo_tiles` are keyed per
  region; `_backup_layer_tile` snapshots each region once. Steps 1–4 deep-clone **all** keys,
  so multi-region strokes revert correctly. Verify the test covers ≥2 regions.
- **Multiple sub-tiles in one region.** `duplicate_region_tiles` copies the entire region tile
  dict (all sub-tiles), so a stroke that creates several 64-px sub-tiles in one region is
  snapshotted/restored as a unit. Undo of a later stroke in the same region correctly restores
  the earlier strokes' sub-tiles (they were present in that stroke's pre-snapshot).
- **First stroke on a fresh layer.** Pre-snapshot is `{}` (region had no tiles). Undo calls
  `restore_region_tiles(loc, {})` which **erases** the region's tiles — correct, returns the
  region to uncovered. This is the intended empty-snapshot semantic (`pasture_3d_layer.cpp:214-215`),
  and is only "whole-region" because the whole region was empty before that first stroke.
- **Painting vs sculpting.** Height routing exists today; control/color routing does not
  (`start_operation:1010`). Until step 5 lands, control/color edits go to the region map
  destructively and are undone via the region snapshot only — the layer source is not the
  truth for those, so no layer corruption, but they also aren't non-destructive. Call this out
  explicitly so expectations match.
- **Layer GC interaction.** `gc_layer`/`gc_region` (`pasture_3d_data.cpp`, `pasture_3d_layer.cpp:319+`)
  can free fully-uncovered tiles. GC is *not* invoked during a stroke or during `apply_undo`,
  so it does not race the undo path. After a redo that re-adds coverage, tiles are recreated by
  `set_sample`. No change needed, but the test should avoid asserting on tile *count* across a
  GC boundary.
- **Memory/perf of snapshots.** Snapshots are bounded by the stroke footprint (touched
  regions × their sub-tiles), each a small RGF/RGBA8 image — cheap. The deep clone added in
  step 1 runs once per stroke at mouse-up. No per-pixel-per-frame cost. The redo snapshot
  already deep-copies in `stop_operation:1092-1097`; we are only adding an equivalent isolation
  for the undo side.
- **Base aliasing.** Routing requires `layer_count > 1`, which guarantees the Base is
  un-aliased (`is_layer_routing` / `_unalias_base_layer` invariant, guide §10.4). `_apply_undo`
  re-points an aliased single-layer Base via `refresh_base_alias()` (`:812`) — irrelevant while
  routing, harmless otherwise. No change.
- **Overlap with the hidden-layers paint guard (separate spec).** Another agent is speccing a
  guard that blocks painting onto **hidden** layers. There is conceptual overlap with
  `start_operation`'s existing locked/reserved guard (`:1011-1014`) — both decide whether a
  stroke is captured into `_stroke_layer`. Coordinate so that: (a) a hidden active layer either
  blocks the stroke (like locked/reserved) **before** any `_backup_layer_tile`/`set_sample`
  runs, so no undo entry is created for a no-op stroke; and (b) if a stroke is blocked, no
  EditorUndoRedoManager action is committed (today `stop_operation` only calls `_store_undo`
  when regions were actually edited — `:1077` — so a fully-blocked stroke already produces no
  undo entry; preserve that). The two specs touch the same `start_operation` block (`:1005-1018`),
  so land them in awareness of each other to avoid conflicting edits.

---

## 7. Testing / verification plan

### 7.1 Automated (headless, extend `src/unit_testing.{h,cpp}`, invoke from
`Pasture3D` `NOTIFICATION_READY` in `src/pasture_3d.cpp` like the other layer tests)

Add `test_layer_stroke_undo_integration` that reproduces the real defect (the existing
`test_layer_undo_restore` is insufficient — it never goes through `_store_undo`/`stop_operation`):

1. Build a `Pasture3DData` with a region and a 2-layer stack (Base + one un-aliased height
   overlay, REPLACE), so `is_layer_routing()` is true.
2. Simulate a stroke into the overlay: take a pre-snapshot of the touched region tiles, write
   several `set_sample`s across **two sub-tiles** (and ideally two regions), composite, and
   take the post-snapshot — mirroring what `_operate_map`/`stop_operation` do.
3. Critically, **emulate the aliasing hazard**: after building the payloads, `clear()` the
   source dictionaries (as `stop_operation` does) and assert the stored payloads still contain
   the tiles (i.e., they were deep-isolated). This is the regression guard for the root cause.
4. Apply the undo payload via the same restore primitives and assert: the overlay's value at
   the stroke pixels is back to pre-stroke (weight 0 / region erased for a first stroke), and
   a fresh `composite_region` yields the pre-stroke region bytes.
5. Apply the redo payload and assert the stroke is fully re-applied (value+weight) and the
   composite matches the post-stroke bytes.
6. Multi-region/multi-sub-tile variant: assert only the stroke's regions/sub-tiles change and
   a co-located prior stroke in the same region survives the undo.

Run via the project's headless Godot 4.6 path (see memory: `python -m SCons platform=windows
target=editor`, then run the test scene headless). Expect all assertions PASS plus the full
existing suite still green.

### 7.2 Manual (in-editor) — the definitive check for "single stroke, not whole layer"

1. Open a terrain, add a height layer in the Layers dock, make it active.
2. Make **stroke 1** (e.g. raise a bump at spot A). Make **stroke 2** (raise a bump at spot B,
   different region). Make **stroke 3** in the **same region as stroke 1** (spot C).
3. Press **Undo once** → only stroke 3 reverts; strokes 1 and 2 remain. Press Undo again →
   stroke 2 reverts; stroke 1 remains. Undo again → stroke 1 reverts; terrain is flat/base.
4. **Redo** three times → strokes reappear one at a time in order.
5. **The desync regression check (this is what currently fails):** after undoing stroke 3,
   change the active layer's **opacity** (or toggle visibility off/on, or add another layer) to
   force a recomposite. The undone stroke 3 must **stay** undone and strokes 1/2 must be
   unaffected. Before the fix, the recomposite re-derives from the stale layer source and the
   layer appears wrong/cleared; after the fix it is stable.
6. Save the scene, reload, and confirm the post-undo state persists (layer source on disk
   matches the undone state).
7. Repeat the analogous flow for painting once §4 step 5 (control/color routing) lands; if that
   step is deferred, verify control/color undo still works via the region path and document the
   non-routed behavior.

Acceptance: each Undo reverts exactly one stroke (layer source AND composite), Redo re-applies
exactly one stroke, other strokes/layers are never disturbed, and a forced recomposite after
undo does not resurrect or wipe content.

---

## 8. Summary of files & key lines to change

- `src/pasture_3d_editor.cpp`
  - `_store_undo` `:679-691` (build deep-isolated `tiles` payloads), `:702` and `:706`
    (isolate undo and redo payloads symmetrically).
  - `stop_operation` `:1100-1107` (optional: reassign members instead of `clear()`).
  - `start_operation` `:1005-1018` (optional step 5: control/color routing; coordinate with
    the hidden-layers paint-guard spec).
- `src/unit_testing.{h,cpp}` + `src/pasture_3d.cpp` READY hook — add the integration test.
- No changes to `Pasture3DLayer` primitives, `composite_region`, save/load format, or the
  GDScript plugin/undo bridge (`editor_plugin.gd:503-520`).
