# Pasture3D Layer Brush Spec

**Status:** SPEC — not started. Written 2026-09-14 from three interview rounds with the user (decisions in
§2). **Revision 2 (same day):** the pipeline is now **Layer first, children over it**. The first draft ran
the Layer stack over the children's staged sum. That design, its staging buffer and its staged cache are
gone.
**Target:** Godot 4.7, Pasture3D `main` (after b8662535, "Bake Scale applies to Terrain Graph modifiers").
**Builds on:** `PASTURE3D_TOOL_LAYER_ASSIGNMENT_SPEC.md` (owner-keyed brush layers, `tool_layer` dropdown),
the brush modifier stack (`PASTURE3D_BRUSH_EROSION_SPEC.md` §6, `modifier_margin` §6.8.1), and the
Live-preview / bake-scale work (threaded rasteriser, `live_preview_resolution`, `bake_scale`).
**Expected scope:** mostly GDScript (`connectors/pasture3d_terrain_brush.gd`, a new
`connectors/pasture3d_layer_brush.gd`, `layers_dock.gd`, the editor plugin for §7.5). The native work is one
stack entry point that takes supplied `basey` / `amp` / `profile` arrays instead of an outline (§7.3).

---

## 1. Goal

A container node, **`Pasture3DLayerBrush`**, that is to terrain brushes what `Pasture3DRoadNetwork` is to
roads: a group that owns one layer. It:

1. Creates a reserved height layer on its `Pasture3D` terrain, **named after the node**.
2. Renames that layer when the node is renamed.
3. Assigns every painting brush beneath it to that layer automatically.
4. **Refuses** (with `push_error`) any attempt to put a non-member brush on its layer, or to move a
   member brush onto a different layer.
5. Hosts a **modifier stack with graph support**, like Mound/Plow. The stack runs **first**, over the
   layer's extent (the whole terrain, the children's outlines, or selected regions). The children then bake
   **over its result**, reading it as their source.

> **Naming.** `Pasture3DLayer` is already taken: it is the C++ layer `Resource`
> (`src/pasture_3d_layer.h:32`). The node is therefore `Pasture3DLayerBrush`. The editor add-node name and
> docs can still say "Layer brush".

---

## 2. Decisions (interview, 2026-09-14)

| # | Question | Decision |
|---|---|---|
| D1 | Pipeline order | **Layer first, then children over it** (revision 2, replacing "children's sum → stack"). The Layer stack runs on the ground below and writes its result. Children then bake on top, reading *ground below + Layer result* as their base: surface snap, `basey`, and their own modifier stacks, erosion included. |
| D2 | Stack extent | **Three modes: `WHOLE_TERRAIN`, `CHILDREN_FOOTPRINTS`, `WHOLE_REGION`.** The default is Whole Terrain. When the first member joins an *empty* Layer that is in Whole Terrain mode, the mode switches to Children Footprints. When members already exist, adding one leaves the mode alone. |
| D3 | Point-modifier `profile` | Whole Terrain → **uniform 1**. Children Footprints → **the union of the children's outlines**, feathered across `modifier_margin`. Whole Region → **1 inside the selection**, feathered outward. |
| D4 | Membership violations | **Refuse + `push_error`.** The assignment is rejected, the value stays as it was, the error names both nodes, and the Layer lists it in its configuration warnings. |
| D5 | Identity and rename | **The node name is the truth.** The owner id is stable per node, so a rename never rebinds members. A node rename renames the layer row. A dock rename of a Layer-owned row is refused. On a name collision the name is de-duplicated and the node is renamed to match. |
| D6 | Deleting the node | **The layer rows are removed in the same undo action.** Undo restores them. |
| D7 | Membership and nesting | **Nearest Layer ancestor.** A painting brush belongs to its nearest `Pasture3DLayerBrush` ancestor, at any depth (plain `Node3D` folders are fine). A nested Layer is its own layer. Non-painting nodes are ignored. |
| D8 | Mode after the last member leaves | **Stays as set.** Only the empty → first-member transition changes the mode, and nothing ever switches it back. |
| D9 | Whole Region selection | Picked with a **viewport Select Regions tool** and also stored as an inspector-editable list (§7.5). |
| D10 | Whole Region seams | **Margin skirt outward.** `modifier_margin` applies at every selected/unselected boundary: the stack solves into neighbouring regions and feathers out. |
| D11 | Whole Region and children | Children bake wherever they are. Outside selection ⊕ margin there is no Layer result, so they bake on the plain ground below. |
| D12 | Whole Region and the mode rules | **The auto-flip (D2) fires only from Whole Terrain**, so a Whole Region choice is never overridden. A deleted selected region is dropped with a warning (restored on undo). An empty selection runs no stack and warns. |
| D13 | Road brushes | **Cannot be members.** Roads are grouped by `Pasture3DRoadNetwork`. A road brush under a Layer keeps its own binding and shows a warning. |
| D14 | Stack order | **Inserted once, then the user owns it.** Reordering the scene tree never moves rows. |
| D15 | No children | **The stack still runs** in Whole Terrain and Whole Region modes. A Layer with only Noise or a generator graph is a legitimate terrain-wide layer. |
| D16 | Dock presentation of the two rows | **One row per Layer in the Layers dock.** With no children the base row is shown; with children the main row is shown. The other row is hidden from the list, and every dock action on the shown row applies to **both** (§8.3). |

---

## 3. Identity (D5)

### 3.1 Owner id and the row pair

```
const LAYER_BRUSH_OWNER_PREFIX := "pasture3d_layerbrush:"
const LAYER_BASE_SUFFIX := "#base"
@export_storage var _layer_uid: String = ""        # generated once; never derived from the name
func layer_owner_id() -> String: return LAYER_BRUSH_OWNER_PREFIX + _layer_uid
func base_owner_id()  -> String: return layer_owner_id() + LAYER_BASE_SUFFIX
```

A Layer brush owns **two rows**, kept adjacent in the stack:

| Row | Owner | Holds | Blend |
|---|---|---|---|
| **Base** (lower) | `base_owner_id()` | The Layer stack's result: absolute heights where the stack moved a cell, NaN elsewhere | REPLACE, fixed |
| **Main** (upper) | `layer_owner_id()` | The children's output, exactly as a shared brush layer holds it today | `blend_mode` (Layer property) |

**Why two rows.** Children read "the ground below their layer" through
`composite_height_below(layer_id, …)`, which every snap, `basey` fill and below-reading modifier already
uses. Put the Layer result in a row directly beneath the children's row, and D1 falls out of that existing
read with **no rasteriser change**. It is the same reasoning that made `create_owned_layer` idempotence
deliver layer sharing for free. A single row would need the base passed into every child read path
explicitly: the snap, the native `basey` pre-pass, and the GDScript oracle. That is three sites that must
agree (memory: *component gates miss wiring*).

The `owner#suffix` form is the existing affiliated-row convention (graph sinks' `owner#graph_color`), so
`_all_layers_for_owner`, `_snapshot_owner` / `_restore_owner` and undo already cover both rows.

- Rows are created with `create_owned_layer_typed(owner, name, blend, TYPE_HEIGHT)`, which is idempotent by
  owner, so a reload binds back to the existing rows. Both rows are named `<name>`, because the dock only
  ever lists one of them (D16, §8.3).
- **Members store the Layer's main owner id in their existing `_layer_owner`.** No new binding field.
- The prefix is **not** `pasture3d_brush:`. That keeps both rows out of `_brush_layers()`, so free brushes
  never see them in their `tool_layer` dropdown. This is half of the refusal in §5: the easiest bad
  assignment is one the UI can't offer.
- **Duplicate / paste:** a duplicated node carries the same `_layer_uid`. On `ENTER_TREE` (`_ready_done`
  false), if another `Pasture3DLayerBrush` on the same terrain already holds the uid, the newcomer generates
  a fresh uid, de-duplicates its name, creates its own row pair, and rebinds its duplicated members (LB-E).

### 3.2 Rename

- Node → rows: on `NOTIFICATION_PATH_RENAMED` (editor), call `set_layer_name` on both rows, then
  `_update_label_text()` on each member, whose nameplates show the layer name.
- Collision: if another row already has the new display name, pick `_unique_brush_layer_name` (extended to
  scan *all* rows, not just brush rows) and rename the **node** to it. This runs deferred, so the rename in
  progress finishes first, and re-entry is guarded because renaming the node fires PATH_RENAMED again.
- Dock → row: `layers_dock.gd` refuses to rename a row whose owner begins with `LAYER_BRUSH_OWNER_PREFIX`,
  and shows "Rename the Layer brush node '<path>' instead." A scripted `set_layer_name` is not intercepted:
  the next PATH_RENAMED or the Layer's `_ready` puts the name back and `push_warning`s.

---

## 4. Membership (D7, D13)

### 4.1 Rule

A node **M** is a member of Layer **L** iff:
- `M is Pasture3DTerrainBrush`, `M._paints()`, `M._map_type() == TYPE_HEIGHT`,
  `not (M is Pasture3DRoadBrush)`, `M.terrain == L.terrain`, and
- L is M's nearest `Pasture3DLayerBrush` ancestor.

This is a pure function of the tree, computed by `Pasture3DLayerBrush.layer_host_of(node)`. It is *never
stored* on the member: `_layer_owner` is the only persisted state, and it is re-derived from the tree.

A brush under a Layer that fails the type checks is **not** a member. It keeps its own binding and gets a
configuration warning:
- Road brush: "Road brushes are grouped by a Pasture3DRoadNetwork, not a Layer brush."
- Control/colour brush: "Layer brushes host height brushes only."

### 4.2 Assignment moments

| Event | Behaviour |
|---|---|
| Brush added / pasted / instanced under L | The member's `_layer_owner` is set to L's main owner, and its `terrain` to L's terrain. It bakes through L (§6). **Not an error.** |
| Free brush reparented under L | Its footprint is lifted from its old layer (existing `_rebind` path), then it joins L. **Not an error.** Dragging a brush into a folder is how you use the feature. |
| Member reparented out of all Layers | It is given a fresh free layer named after itself (`add_new_layer()` semantics), and L re-bakes without it. **Not an error.** |
| Member reparented to another Layer L2 | Detach from L, join L2. Both re-bake. |
| Scene load | In `_ready`, each member *checks* that `_layer_owner` matches its host. On a mismatch (for example a scene edited by hand), it adopts the host's owner and `push_warning`s. It does not error, because nobody tried to break the rule. |
| Layer on a different `terrain` than its member | L's terrain wins. The member follows it, the same way `_auto_assign_terrain` already follows a Pasture3D ancestor. A Layer with no terrain ancestor warns and paints nothing. |

The first-member switch (D2) fires only while `extent_mode == WHOLE_TERRAIN` (D12), when L goes from 0
members to ≥1 through one of the rows above. It does **not** fire on scene load. The check is "was empty and
the member set just grew", evaluated after the tree settles (the existing `_tree_settling` pattern, so a tab
switch's churn does not count).

### 4.3 Nesting

Each nested Layer is independent, with its own row pair, members and stack. At creation its pair is inserted
above its parent Layer's pair. After that the user owns the order (D14). A Layer's stack reads the ground
below **its own base row**, like every brush, so whether it sees a nested Layer's output depends only on
where the user has put the rows.

---

## 5. Violations (D4)

Both are refused at the single place an assignment happens: `_set_layer_owner(owner)` on
`Pasture3DTerrainBrush`. Every path already funnels through it (`tool_layer` dropdown,
`_assign_layer_by_name`, `add_new_layer`, scripts).

```
func _set_layer_owner(owner: String) -> void:
    if owner == _layer_owner: return
    var host := Pasture3DLayerBrush.layer_host_of(self)
    if host != null and owner != host.layer_owner_id() and not _membership_transition:
        push_error("Pasture3D: '%s' is a member of Layer brush '%s' and cannot be moved to layer '%s'. Move the node out of the Layer first."
            % [get_path(), host.get_path(), _display_for(owner)])
        host._note_violation(self, owner); notify_property_list_changed(); return
    if host == null and owner.begins_with(Pasture3DLayerBrush.LAYER_BRUSH_OWNER_PREFIX) and not _membership_transition:
        push_error("Pasture3D: '%s' cannot be assigned to layer '%s' — it is owned by Layer brush '%s'. Make it a child of that node instead."
            % [get_path(), _display_for(owner), _layer_brush_for_owner(owner).get_path()])
        ...; return
    ...existing body...
```

- `_membership_transition` is set only by §4.2's tree-driven moves, so those never trip the refusal.
- The prefix test catches the base row too (`#base` owners share the prefix), so nothing can be assigned to
  it.
- `notify_property_list_changed()` on refusal matters. The inspector's enum already shows the rejected
  value, and a dynamic hint does not repaint without it (memory: *property hints need notifying*).
- The member's `tool_layer` stays editable but shows only its current layer while it has a host. The
  refusal is the mechanism, and the narrowed dropdown is a courtesy. Keep both.
- `_note_violation` records `{node path, attempted layer, time}` in a non-persisted list, which the Layer's
  `_get_configuration_warnings` shows until the next successful bake. After a refusal the scene is
  unchanged, so the warning records the attempt, not a broken state.

---

## 6. Bake pipeline (D1)

### 6.1 Who drives

The **Layer** is the owner-level driver for its rows. For a Layer-owned owner, every member's `refresh` /
`_schedule_*` forwards to `host.<same>` with the member's dirty data (dirty splines, boxes, moved node). This
gives one debounce timer, one deferred run and one undo action per Layer, however many members changed.

`Pasture3DLayerBrush` extends `Pasture3DTerrainBrush`. `_paints()` returns false for its own outline (it has
no splines) and `_supports_modifiers()` returns true. It overrides the owner-level bake with two stages:

```
_refresh_owner(owner):                       # full; the rect variant is §6.3
  STAGE 1 — BASE (skipped when the base key matches, §6.2)
    1. extent  := _stack_extent()              # §7.1
    2. below   := composite_height_below(base_row, extent grid)
       amp     := 0 everywhere                 # the Layer adds nothing of its own
       profile := §7.2
    3. result  := run Layer stack(below, amp, profile, extent)   # §7.3
    4. clear base row in extent; write result where |result − below| ≥ MODIFIER_MARGIN_EPS, NaN elsewhere
    5. composite base row over extent; store base key
  STAGE 2 — CHILDREN (today's shared-layer bake, unchanged)
    6. clear main row over children's footprints (+ the base's changed box, §6.3)
    7. children: snap, then _paint_into(main_row, blend) with _defer_composite
       → every read of "below" now sees ground + base (it is the row beneath)
    8. composite + targeted GPU push + undo (both rows) + baked signal, as today
```

- **Empty stack:** stage 1 writes nothing (every cell is within epsilon), so the base row is all NaN and
  stage 2 is bitwise identical to today's brushes on a shared free layer (LB-A).
- **Why NaN below epsilon, not a full write:** the base row is absolute REPLACE. Writing every cell would
  freeze the ground below at bake time, so a later edit to a lower layer would be hidden under a stale copy
  wherever the stack did nothing. Only cells the stack actually moved are held.
- **Children never see siblings.** A child's "below" is ground + base, not the other children, which is the
  same as today's shared layer. Child stacks do local shaping over the Layer's result.

### 6.2 Base key (what makes stage 1 skippable)

The base is a pure function of: the below digest over the extent, the extent itself (§7.1 `_extent_key`),
the profile inputs (in Children Footprints mode, each child's **outline** signature: `shape_key` plus its
curve cache; in Whole Region mode, the sorted selection), and the Layer's `_modifier_signature`. It does
**not** depend on the children's heights, blend, strength or modifiers.

- Key on **all** of those. The below digest is the one that is easy to forget: the base row is absolute
  output, so a lower-layer edit must invalidate it (memories: *cache on the output, not the input*;
  *memoised programs hide invalidation*).
- The key is stored beside the base row (`@export_storage var _base_key`), so a reload skips stage 1 until
  something changes.
- Consequence worth stating in the tooltip: **in Whole Terrain mode, no child edit ever re-solves the
  base**. The cost of a terrain-wide erosion is paid on stack, mode or lower-layer edits, never per brush
  drag.

### 6.3 Rect bakes

| Edit | Stage 1 | Stage 2 |
|---|---|---|
| Child param / height / child modifier (outline unchanged) | skip (key matches) | rect over the child's dirty box, as today |
| Child outline moved, Whole Terrain or Whole Region | skip | rect, as today |
| Child outline moved, Children Footprints | **re-solve**. If the stack has a field step (erosion, smooth, input-reading graph), over the whole extent. If point-only, over the dirty box ⊕ margin | every child overlapping the box where the base **changed** (diff old vs new base row), clipped to that box |
| Layer stack / mode / selection / margin edit | re-solve over the (old ∪ new) extent | every child overlapping the changed box |
| Lower-layer edit under the extent | detected at bake time (staleness is a bake-time fact, as for brushes) | as above |

Stage 2 after a base change must use the **changed box**, not the child's own footprint only. A child whose
footprint straddles the edge of the change is clipped, and its other half is still valid. The existing
`_refresh_owner_rect` clipping handles this (memory: *road batter overwrote other roads* is the precedent for
why a clip must be exact).

---

## 7. The Layer's stack

### 7.1 Extent (D2, D9)

```
enum ExtentMode { WHOLE_TERRAIN, CHILDREN_FOOTPRINTS, WHOLE_REGION }   # append only; the int is stored
@export var extent_mode: ExtentMode = WHOLE_TERRAIN
@export var selected_regions: Array[Vector2i] = []   # region grid coords; Whole Region only
```

- `WHOLE_TERRAIN`: the union of `terrain.data` region bounds (`_region_coverage()` /
  `covered_region_bounds`). `modifier_margin` is hidden (there is nothing beyond it to skirt into).
- `CHILDREN_FOOTPRINTS`: the union of members' outline footprints, grown by `modifier_margin`, snapped to
  layer tiles (`_snap_aabb_to_tiles`). No members → empty extent → no stack runs, and the base row is
  cleared.
- `WHOLE_REGION`: the union of the selected regions' world bounds (region location × `region_size` ×
  `vertex_spacing`), grown by `modifier_margin` and snapped to layer tiles. The margin may cross into
  unselected **or nonexistent** neighbours. Cells with no region are NaN in `basey`, and the stack must
  treat them as it treats off-terrain cells (**verify**: the Footprints margin can already hit this at the
  map edge). `_extent_key` folds in the **sorted** selection.
- The extent key feeds Frozen caches exactly as it does for a brush. Switching mode changes the key, so
  Frozen steps go stale and the existing staleness warning applies. **Switching mode does not clear
  caches**, so switching back serves them again.

### 7.2 Profile (D3, D10)

| Mode | `profile` | Feather source |
|---|---|---|
| Whole Terrain | 1 everywhere in the extent | none |
| Children Footprints | 1 inside the union of children's outlines, smoothstep 1→0 over `modifier_margin` outside it | distance to the outline union, computed **before** any child bakes |
| Whole Region | 1 inside the selected regions, smoothstep 1→0 over `modifier_margin` outside | the selection is a union of axis-aligned squares, so the distance is **exact and analytic**. Don't route it through JFA "for consistency", or the oracle becomes approximate for no reason |

**Children Footprints distance.** Closed outlines give an interior; open splines give their corridor, as the
brush already defines it. Get the union distance from the **same machinery the graph's Shape Source uses**
on `graph_shape_path()`, so "where a child is" has exactly one definition (memory: *JFA, not an exact
distance transform*, "the disc must be defined exactly once"). Two rules:
- Not the children's footprint AABBs: a thin diagonal brush would cover a large square.
- Not a blur of a coverage mask: blur is inert on straight edges (memory: *brush corner rounding is a
  fillet*).

The filter-vs-generator rule of §6.8.1 carries over unchanged. An input-reading graph gets mask 1 inside
the covered area (everywhere in Whole Terrain mode). A generator graph keeps the profile falloff.

### 7.3 Native entry

Mound/Plow run the stack inside their rasterise, where `amp`, `basey`, `sdf` and `profile` are built from
the outline. The Layer needs **the same step loop** with those supplied as arrays:

```
Pasture3DData.brush_run_stack_on_field(params, basey: PackedFloat32Array, amp: PackedFloat64Array, profile: PackedFloat64Array) -> PackedFloat32Array
```

**Built (phase 2).** On `Pasture3DData`, not `Pasture3DUtil`: relief fields fall back to `get_height` for NaN
ground, which needs the data. `params` is the Mound's dictionary shape (grid, `blend`, `modifiers`,
`op_selectors`, fit frame, `need_fields`, `sim_result`, optional `base_below`). The shared loop is
`brush_run_step_loop` in `pasture_3d_brush_raster.cpp`, templated on two callbacks: the point-run mask and the
graph feather. Host Profile selectors read an empty field on a Layer. LB-B lives in
`bench/LayerBrushStepLoopGate.tscn` and compares against heights recorded by the pre-extraction build. Its
control is a 1e-4 strength nudge that must move a probe, not a per-modifier fold, which would need a debug
switch in the kernel.

It reuses the step loop, point-run folding (double precision), selector rebase, deferral, preview_scale and
bake_scale handling. The one rule is **no second implementation of the step loop**: extract it from
`stamp_mound_loop` so both callers share it, and gate that Mound output is bitwise unchanged after the
extraction (LB-B). The GDScript `_run_modifier_stack` already takes arrays, so it stays the oracle.

### 7.4 Properties

- **Modifiers group:** `extent_mode` (top), `modifier_margin` (Children Footprints and Whole Region),
  `live_preview_resolution`, `bake_scale`, `modifiers`.
- `selected_regions` and a **Select Regions** toggle button, shown only in Whole Region mode (§7.5).
- `blend_mode`: the main row's blend, synced both ways as `_ensure_layer_for(sync_blend)` does today. The
  base row is always REPLACE and is not exposed.
- A read-only **Layer Stats** group: member count, extent size, cells, cells held in the base row, and
  whether the last bake re-solved the base or skipped it.
- Hidden brush-only groups: Surface, corner/crease, splines, Add Spline / Add Water, `tool_layer`, and Mask
  Preview unless a Relief modifier exists.
- Buttons: **Refresh**, **Bake** (`force_bake_modifiers`, full resolution), **Select Members**.

### 7.5 Select Regions tool (D9, D12)

**What it is.** A viewport interaction mode owned by the selected `Pasture3DLayerBrush`, not a new
Pasture3D editor `Tool`. It reuses the tile picking of the existing REGION tool
(`src/pasture_3d_editor.h:19`) but **never adds or removes regions**.

- **Entry.** The **Select Regions** inspector button, or the toolbar button shown while a Layer brush in
  Whole Region mode is selected. It exits on Esc, on deselecting the node, or on pressing the button again.
  While active it consumes viewport clicks (via the plugin's `_forward_3d_gui_input`), so brushes aren't
  selected by accident.
- **Interaction.** Click a region to toggle it. Drag to paint: the first tile's new state (on or off) is
  applied to every tile the drag crosses. Clicking where there is no region does nothing and shows a
  status hint ("No region here — use the Region tool to add one").
- **Overlay.** Selected regions get a translucent fill, and the hovered region an outline. It is drawn by
  an INTERNAL child (not saved), the same pattern as the nameplate `Label3D`, and shown only while the tool
  is active or the node is selected.
- **Undo.** One `EditorUndoRedoManager` action per click or drag ("Select Regions"), on `selected_regions`.
  The setter schedules a Layer bake. A drag bakes once on release, not per tile.
- **Inspector list.** `selected_regions` is a plain editable `Array[Vector2i]`, sorted and de-duplicated
  in the setter. Entries naming no existing region stay in the list but are ignored, and are listed in
  configuration warnings.

**Region lifecycle (D12).**
- A selected region is removed (REGION tool): on the terrain's region-change signal (**verify** which
  `Pasture3DData` signal fires for add/remove), drop the coordinate from the selection with
  `push_warning`. Use a plain property write, *not* a separate undo action, and record it in a stored
  `_dropped_regions` list. When the REGION tool's own undo re-adds a region in that list, it is re-selected
  and the entry cleared. Gate it (LB-O): this is the between-components wiring that component gates miss.
- Empty (or all-invalid) selection: no stack runs, the base row is cleared, and a configuration warning
  says "Whole Region mode with no regions selected".

---

## 8. Lifecycle

### 8.1 Creation

`_ready` (editor, terrain resolved): create or bind the row pair via §3.1, place it (§8.3), and adopt the
existing members (§4.2 load row). Brushes dragged under a Layer later follow §4.2.

### 8.2 Deletion (D6)

On editor removal, while still in the tree, the Layer adds to the delete's undo action: the do step removes
both rows and every affiliated `owner#…` row, and the undo step re-inserts them at the same indices with
their tile data (model: `_snapshot_owner` / `_restore_owner`). Members are deleted with the node, so their
`_detach_from_current` must see the host is leaving and **not** repaint or rebind to free layers first.
Guard with a `_host_leaving` flag set before children exit.

**Trap to gate (LB-F):** the editor keeps deleted nodes in undo history outside the tree, and
`_detach_from_current` already special-cases that. A Layer delete + undo must leave both rows bitwise equal
to before, with members bound to the same owner. A scene save between the delete and the undo must not
re-save demo data (memory: *gate data_directory is an editor risk*).

### 8.3 Stack order (D14)

A new Layer's pair is inserted above the terrain's current top brush layer (a nested Layer: above its
parent's pair). After that the user owns the order in the dock. The scene tree never re-sorts rows.

### 8.4 One row in the dock (D16)

`layers_dock.gd` lists a Layer brush's pair as **one row**:

| Layer state | Row shown | Row hidden |
|---|---|---|
| No members | base (the stack's result is the Layer's whole contribution) | main (empty) |
| ≥1 member | main | base |

The shown row is picked at each `refresh()` from `Pasture3DLayerBrush.member_count()`, found through the
uid in the owner id. With no Layer node found (an orphan pair), **main** is shown with the orphan badge.

**Implementation notes, from reading the dock:**
- Rows already find their layer through `row.get_meta("layer_idx")`, not their position in the list, so
  skipping the hidden row in the `for i in range(count - 1, -1, -1)` build loop is safe for clicks.
- **The active layer can be a hidden row** (a script, undo, or the Layer's own bake calling
  `set_active_layer`). `_sync_active_state` maps an active hidden row to its shown partner for the highlight
  and the toolbar's enabled state.
- **Move up/down is ±1 in stack indices today** (`_move_active`), which would step onto the hidden partner
  or split the pair. Moves become **display-order** moves: the moving unit (a single row, or a pair) swaps
  past the next *visible* unit, which may itself be a pair. Drag-and-drop (`_drop_row`) uses the same
  unit-aware path.
- **Undo.** `_move_layer_undoable` relies on `move_layer` being its own inverse for ONE row. A pair move is
  two `layer_move` calls, and its undo must replay the inverse moves **in reverse order**, or the pair comes
  back swapped. Record the list of `(from, to)` steps as data and invert it (the Bake All undo precedent),
  in one undo action.
- The empty-layer warning badge is suppressed on a Layer pair. An empty main row with no members is the
  normal state, not a problem.

**Every dock action applies to both rows:**

| Action | Behaviour on a Layer row |
|---|---|
| Visible | set on both |
| Lock | set on both |
| Opacity | set on both (the base scales the Layer result, the main row the children, so the Layer fades as one) |
| Move up / down / drag | the pair moves as one unit, base directly beneath main |
| Blend | writes the **main** row and the Layer's `blend_mode`. The base stays REPLACE (§3.1), because its cells are absolute results |
| Rename | refused (§3.2) |
| Duplicate / Remove / Clear | refused, with a hint: duplicate or delete the Layer node, or press **Bake** on it. The rows are derived output of that node, so a dock edit to them would be overwritten or orphaned |

**The pair is kept in step, not trusted to stay in step.** Visibility, lock, opacity and adjacency can still
drift through scripts or older scenes. At the Layer's next bake, and at dock `refresh()`, the hidden row is
re-synced from the shown row and the pair re-joined if separated, with `push_warning`. Stage 2 depends on the
base being the row directly beneath (§3.1), so adjacency is an invariant, not a preference (LB-Q).

---

## 9. Integration with existing systems

| System | Behaviour |
|---|---|
| Hand painting | Both rows are reserved and refuse strokes (memory: *brush layers are not hand-paintable*). |
| Orphaned-layer notice (`layers_dock.gd`) | Recognises `LAYER_BRUSH_OWNER_PREFIX` rows. A pair with no `Pasture3DLayerBrush` holding its uid is an orphan. |
| Bake All / eroding-brush registry | A Layer with erosion or graph modifiers registers like a brush. The unit of work is the Layer: its frozen caches are cleared and `_base_key` is invalidated, then the base re-solves and its children re-bake over it. |
| Live / Frozen / deferred driver | The Layer is the run owner. **The base is a phase before the children**: children's pass 1 (which collects their pending solves) runs only after the base result is committed, or they would solve against the previous base. Newest-edit-wins supersede is unchanged. LIVE_ROUNDS applies per stage. Measure with the driver's round counter before changing the constant. |
| `live_preview_resolution` / `bake_scale` | Independent on the Layer and its members. Frozen / Bake / Bake All stay full resolution for both. |
| Graph sources / sinks | `Pasture3DGraphSources.resolve(graph, host)` is called with the Layer as host. A Shape Source naming a member resolves through `shape_key()` as today. The Layer itself offers **no** shape (`graph_shape_count() == 0`). |
| Road brushes | Not members (D13). The road system reads the ground as it does today, which now includes a Layer's rows where they sit beneath the road's layer. |

---

## 10. Phases

1. **Identity + membership, no stack.** Node, uid, row pair create/rename/delete/move-as-pair, §4
   assignment, §5 refusal, children baking through the Layer driver. Gates LB-A, LB-C, LB-D, LB-E, LB-F,
   LB-J, LB-Q, LB-R.
2. **Native entry.** §7.3 loop extraction. Gate LB-B.
3. **Base stage, Whole Terrain + Children Footprints.** §6.1 stage 1, §6.2 key, §6.3 rect table, §7.1–7.2
   for the first two modes, first-member flip. Gates LB-G, LB-H, LB-I, LB-K, LB-P.
   **Built (2026-09-14)**, gated by `bench/LayerBrushBaseGate.tscn` (A's base-row check, G, H, I, K, P; all
   with controls). The base is written through a new `Pasture3DData.stamp_grid`. Three deviations: a rect
   bake whose base went stale re-bakes the members FULL rather than clipping to the changed box; the
   first-member flip fires from the member's `_ready` (an empty owner is a join), not `_sync_layer_host`
   alone; LB-P checks the snap half only, not a child erosion's flow. Stage 1 runs synchronously until the
   phase 4 driver.
   **Follow-ups closed (2026-09-14).** LB-P now checks both halves: a child erosion's flow grid over the base
   differs from the no-base child, and a member reading past the base row (`read_past_base_row`) gets the
   no-base flow. Flow is read after a deferred run, because the synchronous native step only fills flow when
   a later modifier reads fields. Changed-box clipping is built: `bake_base` diffs the ground under the main
   row before and after, and keeps the box that moved (`base_change()`). A member's rect bake re-solves a
   stale base in place, adds that box to its pieces, and re-seats snapped points inside it. The box is
   dropped by a bake outside a run, or at the end of the Layer's run. Gated in LB-I: a far member stays out
   of the rect; an unmoved eroding member is reached when the base moves under it; both equal a full bake.
   Control: ignoring the box (`rect_ignores_base_change`) differs.
3b. **Whole Region mode + Select Regions tool.** §7.1 region extent, §7.2 analytic profile, §7.5 tool,
   overlay, undo, region-lifecycle listener. Gates LB-M, LB-N, LB-O.
   **Built (2026-09-14)**, gated by `bench/LayerBrushRegionGate.tscn` (M, N, O; all with controls). The
   region-change signal is `Pasture3DData.region_map_changed`, emitted by `update_maps` whenever the region
   map is rebuilt, add and remove alike. Deviations: the Select Regions entry point is the inspector button
   only (no toolbar button yet), and the empty-region hint is an editor toast. The viewport tool, overlay and
   one-action-per-drag undo are editor code no headless gate reaches; they are untested until tried in the
   editor.
4. **Driver and Bake All.** Base-before-children phase ordering in the deferred run, registry. Gates LB-L,
   LB-S.
   **Built (2026-09-14)**, gated by `bench/LayerBrushDriverGate.tscn` (L, S; both with controls).
   `Pasture3DLayerBrush.bake_layer_run` runs stage 1 through its own `_bake_deferred` (so LIVE_ROUNDS
   applies per stage), commits, then runs the members' driver; a member's refresh routes there through
   `_layer_run_host`, keeping its rect bake for stage 2. Bake All plans a Layer under its members' owner,
   invalidates `_base_key`, and bakes the owner as a Layer. `bake_base` ignores a matching key on a driver
   repass, because pass 1 records the key with the un-solved base. `work_log` is the order LB-L reads.
   Deviation: any deferrable work on the Layer or a member now makes the whole Layer the run, so a member
   edit under a Live Layer stack re-checks stage 1 (a key hit skips it) before its own bake.

---

## 11. Gates (`bench/LayerBrushGate.tscn`)

Every criterion needs a control that fails with the mechanism removed, and must count completions
(memories: *bench gate practices*, *gate PASS can mean nothing ran*, *a gate that calls the node measures
nothing*).

| Gate | Asserts | Control (must fail) |
|---|---|---|
| LB-A | Empty-stack Layer with 3 overlapping members ≡ the same 3 brushes sharing one free layer, bitwise, over the union box. The base row holds 0 cells | Write every stage-1 cell instead of NaN below epsilon (the base freezes the ground; a lower-layer edit then differs) |
| LB-B | Mound bake bitwise unchanged after the step-loop extraction, across Noise→Relief→Smooth and a Graph step | Fold the point run per modifier (float rounding) |
| LB-C | Member `tool_layer` set to another layer is refused: owner unchanged, `push_error` count +1, row bytes unchanged, violation listed | Remove the host check in `_set_layer_owner` |
| LB-D | A free brush assigned the main **or base** owner is refused. Neither row appears in a free brush's `_brush_layer_names()` | Give Layer rows the `pasture3d_brush:` prefix |
| LB-E | Rename node → both rows rename. Collision → node renamed to the de-duplicated name. Dock rename refused. Duplicate Layer → distinct uid, its own pair, correct members | Skip uid regeneration on duplicate |
| LB-F | Delete Layer → both rows gone. Undo → rows, tile bytes and member owners restored exactly | Let members `_detach_from_current` during host delete |
| LB-G | Extent: Whole Terrain == region union. Footprints == outlines ⊕ margin. First member into an empty Whole Terrain Layer flips the mode. Second member, last-member removal and scene load don't | Evaluate the flip on load |
| LB-H | Footprints profile: Noise moves no base cell outside outline ⊕ margin, and moves cells at the corner of a thin diagonal child's AABB **zero** times. The feather is monotone along a straight edge | Use footprint AABBs (the corner moves); use a blur (the straight edge is flat) |
| LB-I | Whole Terrain: a child height edit re-solves the base 0 times (counter) and changes only the child's rect. Footprints: moving a child's outline re-solves the base, and every child overlapping the changed box re-bakes | Bake stage 2 against the pre-edit base → measured step at the changed-box edge |
| LB-J | Refusal survives the inspector: property list re-emitted on refusal | Drop `notify_property_list_changed()` |
| LB-K | The base key invalidates on: the stack signature, the mode, the selection, a Footprints outline move, **and a lower-layer edit**. It does not invalidate on a child height edit | Key without the below digest (a lower edit serves the stale base) |
| LB-L | Bake All over a Frozen-erosion Layer: caches cleared, base re-solved once, and children re-baked after it, in that order (work-order log, not a height statistic) | Run children before the base commit |
| LB-M | Whole Region with 2 of 4 regions selected: Noise moves base cells only within selection ⊕ margin, and the feather across a shared edge is monotone and reaches 0 exactly at the margin. The key is unchanged when the selection is reordered. First member into an empty Whole Region Layer does **not** flip the mode | Unsorted selection in the key; auto-flip from any mode |
| LB-N | A member entirely outside selection ⊕ margin bakes bitwise equal to the same member under an empty stack | Profile 1 over the whole extent grid |
| LB-O | Remove a selected region → dropped with a warning, base re-solved. Undo the removal → region back **and** re-selected. The tool never changes `region_locations` | Remove the `_dropped_regions` restore |
| LB-P | **Children read the base.** Over a Layer with a Noise base: a Mound with snap on has point Y == ground + base at its points (not ground), and a child erosion's flow grid differs from the same child without the Layer | Point stage 2's below read past the base row |
| LB-Q | Dock shows exactly one row per Layer: base with 0 members, main with ≥1, and it switches when the first member joins and the last leaves. Visible, lock and opacity on the shown row change **both** rows. Move up/down past a neighbouring pair keeps both pairs adjacent and base-beneath, and **one** undo restores the exact prior indices. Blend changes the main row only. Duplicate/remove/clear are refused. A scripted separation or a visibility mismatch is repaired at the next bake with a warning | Undo a pair move by replaying its steps in forward order (the pair comes back swapped); apply visibility to the shown row only |
| LB-R | A road brush and a control brush under a Layer are not members: bindings unchanged, a configuration warning each, no `push_error` | Drop the type checks from `layer_host_of` |
| LB-S | Deferred run with a Live erosion on the Layer and a Live erosion on a child: the child's solve reads the base from **this** run, not the previous one | Collect children's pending before the base commit |

Perf numbers need asking first (memory: *ask before perf tests*). No gate above times anything.

---

## 12. Resolved questions (2026-09-14)

- **Q1 — Child erosion.** Resolved by D1's reversal: children run over the Layer result, so child erosion
  sees ground + base. Children still don't see each other, as on any shared layer today.
- **Q2 — Road brushes.** Not members (D13). `Pasture3DRoadNetwork` already groups roads.
- **Q3 — Stack order.** Inserted once, user-owned (D14), with the row pair moving as one (§8.3).
- **Q4 — No children.** The stack still runs (D15).

- **Q5 — Two rows in the dock.** Keep two rows in the stack but show one in the dock (D16, §8.4), with
  every dock action applying to both.

## 13. Open questions

None open.
