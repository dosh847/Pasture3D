# Pasture3D — Road Hole Layer: Testing Guide

> How to verify the non-destructive **hole** carving added in layers Phase 7
> (control & color layers). See `PASTURE3D_LAYERS_GUIDE.md` §10.7 for the design.

---

## What the "holes" feature does

A **hole** punches a gap in the terrain: the surface stops rendering and collision
disappears at that vertex, so you can see/pass through it. It is **not** a height
value — it is a single bit packed into the per-vertex **control map** `uint32`
(which also stores texture ids, blend, navigation, etc).

The **RoadPastureConnector** uses holes for **tunnels and bridges/overpasses**:
where a road deck physically covers the ground, you don't want the terrain poking
up through the road surface. `bake_holes()` raycasts down through each road
segment's mesh, finds the terrain vertices fully covered by the road, and marks
them as holes so the ground vanishes under the deck.

### Why Phase 7 changed it

Before Phase 7 the connector carved holes **destructively** (`set_control_hole`
wrote the hole bit straight into the shipped control map):

- **Not idempotent** — move/delete a road and the old holes stayed punched in
  permanently.
- **Destroyed hand-authored control** — a texture or hole you'd painted under the
  road was overwritten with no way to recover it.

This was the last destructive thing the connector did; the road *height* was
already non-destructive (it lives in a reserved "Roads" layer that is cleared and
repainted on every refresh). Phase 7 moves holes into a **reserved control layer**
the connector owns (`<node-path>#holes`). On each bake it clears that layer's
footprint and re-carves, so:

- Moving/re-baking a road leaves **no leftover holes**.
- **Hand-painted control underneath survives** — compositing seeds from the
  hand-authored "base" and only overrides where the road actually carved.
- Baking is **idempotent**.

A fallback to the old `set_control_hole` path remains for terrains/builds without
the layers feature, so plain terrains are unchanged.

---

## Prerequisites

- **Godot 4.6.2** (the version Pasture3D targets).
- The **godot-road-generator** addon installed *and enabled*
  (Project → Project Settings → Plugins). The connector is a bridge node to it.
- A scene containing:
  - a **Pasture3D** terrain node with at least one painted region,
  - a **RoadManager** with a road that physically sits **on or above** the terrain
    surface (so it has covered vertices to hole — a bridge/overpass or a flat road
    laid over raised ground),
  - a **RoadPastureConnector** node with its `terrain` and `road_manager` exports
    assigned.
- Confirm the connector's **Target Layer Name** export is set (default `"Roads"`).
  The hole layer name is derived automatically (`"Roads Holes"`); its owner id is
  the connector's node path + `#holes`.

> Note: the automated unit test `test_layer_control_color` already proves the
> storage / clear / composite mechanism in isolation (32/32 headless). The steps
> below are the **end-to-end editor confirmation** through the real connector.

---

## Test procedure

### Test 1 — Holes carve and are visible
1. Select the connector node, press its **Bake Holes** button.
2. **Expect:** the terrain mesh disappears (a gap opens) directly under the road
   deck where it covers the ground. Move the camera under/around it to confirm the
   ground is actually *gone* there, not merely hidden.

### Test 2 — Idempotent re-bake (the core fix)
1. Press **Bake Holes** again without changing anything.
2. **Expect:** identical result — no new/extra holes, no doubling, the gap is
   exactly the same.

### Test 3 — Holes follow the road (no leftovers)
1. **Move the road** (drag a RoadPoint or the whole RoadContainer) to a clearly
   different spot, then press **Bake Holes** (or trigger an auto-refresh + bake).
2. **Expect:** the hole **moves with the road** — the old location is solid terrain
   again, the new location is holed. (Previously the old hole stayed punched
   permanently — this is the behaviour Phase 7 fixes.)

### Test 4 — Hand-painted control is preserved (the non-destructive guarantee)
1. *Before* baking: use the Pasture3D paint tools to **hand-paint a distinct
   texture** (a different base texture id) on terrain right next to — and partly
   under — where the road sits. Note exactly where.
2. Press **Bake Holes**.
3. **Expect:** the hole appears under the road, but your hand-painted texture on
   the surrounding/adjacent vertices is **untouched**.
4. Now **delete the road** (or its segments) and **Bake Holes** once more (or clear
   the connector's hole layer).
5. **Expect:** the holes vanish and the terrain under where the road was returns —
   **including your hand-painted texture showing through again**. This proves the
   hole layer sits *above* your hand-authored control rather than overwriting it.

### Test 5 — Save/load survives
1. With holes baked, **save the scene** (Ctrl+S), close it, and **reopen** it.
2. **Expect:** holes are still present and correct on load. (The control layer and
   its base round-trip in the `pasture3d_layers*.res` editor files; the shipped
   `pasture3d_<loc>.res` runtime files are unchanged.)

### Test 6 — No regression on plain terrain
1. On a terrain with **no roads / no layers**, confirm normal hole painting (the
   manual hole brush) and the runtime still behave exactly as before.

---

## Red flags to watch for

| Symptom | Likely cause |
|---|---|
| Holes **stay behind** after a road moves | the clear step isn't reaching that region |
| Hand-painted control **wiped** by a bake | base snapshot or topmost-wins compositing is off |
| Holes **disappear on save/reload** | layer persistence regression |
| Runtime `pasture3d_<loc>.res` files change size/content for a height-only edit | persistence regression (runtime format must stay unchanged) |

---

## Status

Baking holes through the connector was **confirmed working in-editor** (2026-06-14).
Tests 1–3 (carve, idempotent re-bake, follow-the-road) exercise the core fix;
Tests 4–6 are recommended for a full non-destructive / persistence confirmation.
