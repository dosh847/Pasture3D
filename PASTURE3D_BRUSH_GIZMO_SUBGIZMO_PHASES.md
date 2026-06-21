# Pasture3D Brush Gizmo — Subgizmo Build-Out Phases

**Goal (user, 2026-06-20):** build the brush gizmo out so a brush's child loops can be
selected and edited *using the same gizmo interface* while the **brush** stays selected —
"all the features of the loop gizmo," to dramatically cut the clicks needed to author maps.
Drag/snap behaviour is governed by the brush's existing **Snap to Surface** + **Surface Offset**.

Files: `project/addons/pasture_3d/src/brush_gizmo.gd` (the `EditorNode3DGizmoPlugin`),
`project/addons/pasture_3d/src/editor_plugin.gd` (input forwarding), `connectors/terrain_brush.gd`
(editor add/remove helpers). GDScript-only — no engine rebuild.

Loop points are exposed as **subgizmos** (not handles), so clicking one shows Godot's standard
move/rotate/scale gizmo while the brush keeps its selection.

---

## Phase 1 — point select → transform gizmo move  ✅ DONE (committed)
Each loop control point is a subgizmo: `_subgizmos_intersect_ray` (screen-space nearest within
`PICK_RADIUS`), `_subgizmos_intersect_frustum` (box-select), `_get/_set_subgizmo_transform`
(translation; Y snapped via `brush._base_height_below()` + `surface_offset` when Snap to Surface),
`_commit_subgizmos` (undoable via `curve.set_point_position`). User-verified.

## Phase 2 — in-place add / remove  ✅ DONE (commit 16d5956)
Plugin forwards 3D input while a brush is selected (`_handles` true for brush; `_edit` keeps the
terrain context live and populates the Layers dock from the brush's parent terrain):
Ctrl-click (Cmd on macOS) inserts a point on the nearest loop segment (snapped); right-click on a
point removes it (refuses below `_min_points()`). Both undoable. User-verified.

## Phase 3 — curve tangents (bezier in/out handles)  ✅ DONE (user-verified)
Expose each point's **in** and **out** tangents as additional subgizmos so loop curvature is
editable in the brush gizmo. Handle-id encodes `kind` (0=position, 1=in, 2=out): `id = gpi*3 + kind`.
Zero-length tangents are drawn/picked at a short outward **stub** so they're grabbable; dragging a
stub grows the tangent from zero (no jump — drag is applied as a delta from the stub start, with the
true pre-drag offset captured for clean undo back to zero). Tangents kept level (offset Y = 0) when
Snap to Surface is on, so the loop stays planar with the surface. Frustum/box-select still moves
**positions only**. Undo via `curve.set_point_in/out`.

**Declutter:** tangent handles are drawn only for the **selected loop point** (tracked in
`_subgizmos_intersect_ray`; a click in empty space clears it). A **"Toggle Tangents"** tool button
(static `Pasture3DTerrainBrush._show_all_tangents`, mirroring "Toggle Labels") shows every point's
tangents at once.

## Phase 4 — niceties (planned)
Close/open-loop toggle; an "auto-smooth point" affordance (seed mirrored tangents so a straight
point becomes a curve in one action); optional slope tilt from `get_normal`; per-point delete key.

## Phase 5 — refinements & backlog
- **Paint-stroke undo on landscape HEIGHT does not undo** (user report 2026-06-20). This is the
  shallow-copy aliasing defect already diagnosed in `.claude/specs/per-stroke-undo-spec.md`
  (`pasture_3d_editor.cpp` `_store_undo` shares `_layer_undo_tiles`/`_layer_redo_tiles` with the
  committed payload via non-recursive `Dictionary::duplicate()`, then `stop_operation` `clear()`s
  them — committed undo/redo end up with empty `layer_tiles`). Fix per that spec §4(A): deep-isolate
  the tile payloads at commit; also isolate the redo payload (line 706); add the integration test.
  **C++ change — needs engine rebuild.**
- "Moving layers cleared the paint layer" — suspected GPU re-push gap in `layer_move` (push all
  affected regions, not just the moved layer's). Needs the Refresh-restores-it confirmation.
- Brush-specific settings defaults (user to supply the per-brush values they kept re-setting).
- Eraser brush for the hand-paint tool (clear a section to reveal layers underneath).
- Fix B (changed-point-only snap) / slope tilt, if still wanted.
