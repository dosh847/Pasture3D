# Pasture3D — Plugin Fork Build Guide

> **Audience:** A Claude (or human) working in the **forked Terrain3D repository** —
> not the game repo. This document is self-contained: it carries every relevant
> finding from the game project (Project Dead Sexy, Laughing Rooster Games) so you can
> build the fork without access to the game's source. Where the game's integration
> contract matters, the exact expectations are reproduced inline.
>
> **One-line mission:** Fork Terrain3D 1.0.1 (MIT) into **Pasture3D** and add a
> **multi-camera geo-clipmap** so a single terrain node renders correct per-camera LOD
> in local split-screen (2–4 players) **against one shared `Terrain3DData`** — i.e. true
> per-view terrain without the duplicate-VRAM cost of running N terrain nodes.

---

## Table of Contents

- [Why this fork exists](#why-this-fork-exists)
- [Background: what Terrain3D is and how it's built](#background-what-terrain3d-is-and-how-its-built)
- [The core problem](#the-core-problem)
- [Everything we learned (grounds the fork)](#everything-we-learned-grounds-the-fork)
- [The core idea (why this is tractable)](#the-core-idea-why-this-is-tractable)
- [Goal / success criteria](#goal--success-criteria)
- [The API contract the game expects](#the-api-contract-the-game-expects)
- [Build plan](#build-plan)
  - [1. Repo, branding, license](#1-repo-branding-license)
  - [2. Build toolchain](#2-build-toolchain)
  - [3. The C++ change (multi-camera clipmap)](#3-the-c-change-multi-camera-clipmap)
  - [4. Shadows](#4-shadows)
  - [5. What the game does on its side (so you can test against it)](#5-what-the-game-does-on-its-side-so-you-can-test-against-it)
  - [6. Upstream sync](#6-upstream-sync)
- [Confirmed API symbols (1.0.1 binary audit)](#confirmed-api-symbols-101-binary-audit)
- [Risks / open questions](#risks--open-questions)
- [Checklist](#checklist)

---

## Why this fork exists

The game needs **local split-screen** (up to 4 players, one machine, one `World3D`).
All player cameras share that single world, so there is exactly **one** terrain mesh
and **one** clipmap center.

Terrain3D's geo-clipmap recenters on **one** camera (`set_camera()`, last-write-wins).
The tracked player gets correct LOD; every other player sees their **own** nearby ground
rendered at the LOD appropriate for *the tracked player's distance*. When karts separate,
the far player's nearby terrain drops to coarse LOD — large triangles snap up and down
through the kart, occluding it.

Two non-fork tiers were tried first and are documented for context:

- **Tier 0 — static-detail clipmap + centroid camera.** *Ruled out.* `mesh_lods` /
  `mesh_size` cannot be raised far enough to keep a whole track at full detail. A
  centroid follow-camera was implemented as a partial mitigation (symmetric degradation
  instead of one broken view) but it does not resolve the artifact.
- **Tier 1 — one Terrain3D node per camera, separated by render layers.** *Works
  functionally* (true per-camera LOD via the public API) **but** each node loads its own
  copy of the terrain data → **VRAM ×N**. Sharing one live `Terrain3DData` across nodes
  via `set_data` **blanks the source node** (ownership reassignment — confirmed in the
  spike). Acceptable on today's small tracks; does **not** survive asset-filled maps,
  worst case 4-player ×4 terrain data.

**This fork (Tier 2) is the terminal answer:** one node, one shared `Terrain3DData`,
N cheap per-camera clipmap instance-sets.

```
Tier 1 (current game spike):  N nodes ×  (clipmap mesh + FULL data copy)            → VRAM ×N
Pasture3D (this fork):        1 node  ×  (N clipmap mesh instance-sets + 1 data copy) → VRAM ×1
```

---

## Background: what Terrain3D is and how it's built

- **Terrain3D 1.0.1**, a high-performance editable terrain system for Godot 4
  (Cory Petkovsek & Roope Palmroos / Tokisan Games). **MIT-licensed** — forking is
  permitted; retain the MIT notice + attribution.
- It is a **C++ GDExtension**. The compiled library ships as `libterrain.<platform>.*`
  and is declared in `terrain.gdextension` with `entry_symbol = "terrain_3d_init"` and
  `compatibility_minimum = 4.4` (fine on Godot 4.6).
- The addon folder vendored in the game (`addons/terrain_3d/`) contains **only the
  GDScript editor tools** (`src/`, `menu/`, `tools/`, `utils/`, `extras/`) plus the
  compiled binaries in `bin/`. **The clipmap/mesh/snap/collision logic you must change
  lives in the C++ source, which is NOT in the game repo** — you read and modify it from
  the upstream `TokisanGames/Terrain3D` repo at the 1.0.1 base.
- Platforms declared in the shipped `terrain.gdextension` (mirror these for the fork):
  Windows x86_64 (debug+release); Linux x86_64 / arm64 / rv64; macOS framework;
  Android arm64; iOS universal; Web wasm32. For the studio's targets, **Windows x86_64
  is the minimum**; add Linux/macOS as needed.

> **Stage save format:** the game saves stages as **binary `.scn`** (a deliberate
> Terrain3D editor optimization — faster load / smaller diffs for the large terrain
> data). This only matters to the game side, but note it if you ever search the game's
> stages: text greps must include `.scn` (`grep -a`). It does **not** affect the fork.

---

## The core problem

A geo-clipmap is built around **one** focal point; it has no concept of N viewers. LOD
is chosen by distance from that single center. Terrain3D exposes exactly one camera hook,
`set_camera()`, last-write-wins. There is no multi-camera / multi-target API; upstream
bundles this into region-streaming work that has not shipped
([TokisanGames/Terrain3D#491](https://github.com/TokisanGames/Terrain3D/issues/491)),
so an addon **upgrade will not deliver it** — a fork is the only path.

This is **not** a networked-multiplayer problem. Across machines each peer has one
camera, so the single-camera clipmap is already correct. The requirement is specifically
**multi-camera (local split-screen) rendering on a single shared world**.

How other engines handle it (for orientation):

- **Per-view LOD** (Unreal Landscape, Unity Terrain): pick tile LOD per camera, render
  the terrain once per view. Split-screen "just works".
- Multi-view clipmap engines either keep **one clipmap instance per camera** (Tier 1 /
  this fork) or drop clipmapping for the playable area and use a **view-independent
  static mesh** at uniform detail (the bounded-arena trick — Tier 0, ruled out here
  because the rings can't cover the track).

---

## Everything we learned (grounds the fork)

From a spike plus a symbol audit of the compiled GDExtension
(`libterrain.linux.debug.x86_64.so`):

- **Single-camera by design.** `set_camera()` is last-write-wins; the clipmap mesh snaps
  to that one camera and LOD is chosen by distance from it.
- **`Terrain3DData` is not shareable across live nodes.** Assigning one node's live
  `data` to a second node via `set_data` **blanks the source** (ownership reassignment).
  This is the crux the fork must fix. Tier 1 worked around it by giving each extra node
  its own `data_directory` (own copy → VRAM ×N).
- **Per-viewport draw is already cheap.** With per-camera render layers + camera
  `cull_mask`, each viewport renders exactly **one** clipmap — same cost as single
  player. The thing we are removing is purely the duplicated **data**, not draws.
- **`mesh_lods` / `mesh_size` can't be raised enough** to keep a whole track at full
  detail (this is why Tier 0 / the static-mesh approach was ruled out). Per-camera
  clipmaps are genuinely required.
- **Material and assets are ordinary shareable resources.** Two terrains can reference
  the same `material` and `assets` safely (the Tier 1 spike does exactly this). Only
  `Terrain3DData` has the blanking problem.
- The data half is **view-independent** (world-space region textures, sampled by world
  position); the clipmap mesh is the **only** view-dependent state (it's recentered /
  snapped to one camera each frame). This separation is what makes the fork tractable.

---

## The core idea (why this is tractable)

Terrain3D already separates the two halves cleanly:

- **Data = view-independent.** The heightmap / control / color region textures are
  world-space; the terrain shader samples them by world position. **One copy serves any
  number of viewers.**
- **Clipmap mesh = view-dependent.** The mesh rings are *recentered (snapped)* to one
  camera each frame; that's the only per-camera state.

So the fork does **not** duplicate the heavy data. It duplicates only the **cheap clipmap
mesh instances** — one set per camera — each snapped/LOD'd to its own camera and tagged
with that camera's render layer, **all sampling the single shared `Terrain3DData` +
material + textures.** That is the entire win over Tier 1.

---

## Goal / success criteria

- One terrain node, `set_cameras([cam0..camN])`, renders each camera's viewport at
  correct per-camera LOD.
- **Single** `Terrain3DData` in VRAM regardless of player count.
- Each per-camera clipmap on its own render layer; cameras `cull_mask` to their own.
- Existing saved `data_directory` folders are **reused (re-pointed), not rebuilt**; the
  game's stages are re-authored with `Pasture3D` nodes (the game's roads serve as a
  rebuild fallback if the data format ever has to change).
- Builds for every shipped platform.
- **Exit check:** 4-player split-screen — correct per-camera LOD **and VRAM ≈ a single
  copy** (flip against the Tier 1 ×N build to confirm the delta).

---

## The API contract the game expects

The game integrates the terrain through a small, stable surface. **Honor these exactly**
so the game can swap `addons/terrain_3d` → `addons/pasture_3d` and only change which
methods it calls — not its overall structure.

**New API to add:**

```
set_cameras(cameras: Array[Camera3D]) -> void   # render one clipmap per camera
get_cameras() -> Array[Camera3D]
```

`set_camera(cam)` must remain as a **one-element shim** (`set_cameras([cam])`) for
backward compatibility and the editor camera.

**Properties the game already reads/writes (keep them, renamed to Pasture3D types):**

- `data_directory: String` — points at saved region data. **Keep the on-disk format
  byte-compatible with Terrain3D 1.0.1** so a node just re-points at existing folders
  and loads unchanged.
- `material` / `assets` — ordinary resources, shared across nodes today.
- `render_layers: int` — VisualInstance layer mask of the clipmap mesh.
- `collision_mode` — must support `FULL_GAME` (and `DISABLED`). See below.
- `data` (`Terrain3DData`) — assignable resource.

**Render-layer convention (reserved range — do not break it):**

The game reserves the **top 4 of the 20 render layers (layers 17–20, bits 16–19)** one
per player for terrain. Gameplay (karts, props) lives on layers 1–16 (bits 0–15) and is
visible to every camera. In the Tier 1 spike:

```gdscript
const GAMEPLAY_MASK: int = 0x0FFFF          # layers 1-16
const TERRAIN_TOP_BIT: int = 19             # player 0 → layer 20 (bit 19), then descending
# player i terrain bit = 1 << (TERRAIN_TOP_BIT - i)
# player i camera.cull_mask = GAMEPLAY_MASK | (player i terrain bit)
```

In the fork, each per-camera clipmap instance-set should be tagged with the layer bit for
that camera index using the **same scheme**, so the game's `cull_mask` math is unchanged.
Document the reserved range (17–20) so gameplay avoids it.

**Collision contract:**

- The game sets `collision_mode = Terrain3DCollision.FULL_GAME` on every terrain node at
  stage load (`PDSStage._ready()`), which builds the whole terrain's collision up front
  for all play modes. This is **independent of cameras** and must stay that way — no
  player falls through regardless of which camera the clipmap follows.
- Background: the default `DYNAMIC_GAME` mode builds collision only within ~64 m of the
  single `set_camera()` camera, so in split-screen the untracked player fell through.
  `FULL_GAME` is cheap at current map sizes (≈48 regions max). The fork should **keep
  one `FULL_GAME` collision on the node** — collision stays single, only rendering goes
  multi-camera.
- `set_camera()` / `set_cameras()` in the fork affect **only the visual clipmap**
  (mesh centering + LOD), never collision.

**Fallback / editor camera:**

- The game registers a non-current fallback `Camera3D` (parked at the start grid) so
  Terrain3D's physics process stays alive and the clipmap is centered near the start
  before player cameras exist. A non-current dummy camera must remain a valid argument to
  `set_camera()` — the centroid mitigation and this fallback both rely on it.
- The editor uses its own camera via `set_camera`; the shim path must keep editing /
  sculpting working.

---

## Build plan

### 1. Repo, branding, license

- Fork `TokisanGames/Terrain3D` at the **exact base of 1.0.1** (record the commit). The
  binaries in the game's `addons/terrain_3d/bin/` are the baseline. Create a `pasture3d`
  branch.
- Brand as **Pasture3D / Laughing Rooster Games**; **retain `LICENSE.txt` (MIT) +
  attribution** to Cory Petkovsek / Roope Palmroos / Tokisan Games and contributors.
- Rename the **addon folder + compiled library + `.gdextension`**:
  `addons/pasture_3d/`, `libpasture.*`, `pasture.gdextension`,
  `entry_symbol = "pasture_3d_init"`.
- **Rename the node classes too:** `Pasture3D`, `Pasture3DMaterial`, `Pasture3DAssets`,
  `Pasture3DData`, `Pasture3DCollision`. Decision: a full rebrand is fine — the game
  accepts re-authoring its 4 stages.

> **Keep the on-disk DATA format compatible — that's what matters.** The node rename
> means re-saving each stage with a `Pasture3D` node, but the terrain heightfields are
> **not** rebuilt. Keep `Pasture3DData`'s `data_directory` loading **format-compatible
> with Terrain3D 1.0.1's saved region data**, so each new node just points at the
> existing saved folders and loads the same terrain unchanged. Forking at the 1.0.1 base
> and not touching the data classes' serialization keeps this free.
>
> **Fallback if the data format must change:** the game's road-generator roads define
> each track, so the terrain can be re-sculpted from the roads — data-format
> compatibility is a convenience, not a hard blocker.

### 2. Build toolchain

- Clone `godot-cpp` matching **Godot 4.6** (the same branch the 1.0.1 base used).
- Build with `scons` per the Terrain3D build docs. **First reproduce an unmodified
  release `.dll`/`.so` and drop it in to confirm a clean baseline** before changing any
  code.
- Target platforms (mirror `terrain.gdextension`): Windows x86_64 (debug+release) at
  minimum; add Linux/macOS for the studio's targets. Maintaining multi-platform builds
  is the real ongoing cost — budget for it.

### 3. The C++ change (multi-camera clipmap)

Work in the main terrain node source (upstream: `src/terrain_3d.cpp/.h` plus the
geoclipmap mesh + snapping code). Function names below are **by role, not verified
symbols** — read the forked source to find where the snap + instance build actually live.

- **Camera list.** Add `Vector<ObjectID> _cameras` and
  `set_cameras(TypedArray<Camera3D>)` / `get_cameras()`. Keep `set_camera()` as a
  one-element shim (`set_cameras([cam])`).
- **Per-camera mesh instance sets.** Where the node today builds one set of clipmap
  `RenderingServer` mesh instances and snaps it to `_camera`, generalize to **one set per
  camera**. All instance sets reference the **same mesh resources** and the **same
  material** (shared `Terrain3DData` textures) — only their transforms (snap) and layer
  mask differ. Reuse the existing snap/LOD math, run per camera.
- **Render layers per camera.** Tag camera *i*'s instance set with the reserved layer bit
  for index *i* (top-4 scheme above; the game uses layers 17–20). The game sets each
  `Camera3D.cull_mask` to gameplay-layers + its own terrain layer.
- **Data stays single.** Never duplicate `Terrain3DData` / textures; every per-camera
  instance set samples the one node's data. **This is the VRAM win** — verify at runtime
  that no internal texture re-upload happens per instance set.
- **Collision unchanged.** One `FULL_GAME` collision on the node, as today.
- **Frame update.** Each frame, snap every camera's instance set to its camera and
  recompute its LOD. Cost = N cheap snaps + N existing instance-sets; per-viewport draw
  stays at one clipmap via cull mask.

### 4. Shadows

Render the terrain shadow caster **once** (not per camera) — the geometry is identical
across the per-camera sets, so one shadow pass is correct for all viewports. Either keep
a dedicated shadow-casting instance set on a layer all shadow rendering sees, or have
only camera 0's set cast (turn `render_cast_shadows` off on the extras). Validate **no
double-shadow / z-fighting**.

### 5. What the game does on its side (so you can test against it)

You don't have the game repo, but this is the integration shape it uses today (Tier 1
spike) and the shape it will use after the fork. Reproduce a minimal version of this in a
test scene to validate the fork.

**Current Tier 1 spike (what the fork replaces):** for split-screen the game spawns N−1
extra `Terrain3D` nodes, each with its own `data_directory` copy, collision disabled,
each on its own render layer, each `set_camera(player_i)`; the authored node is player
0's visual + the sole `FULL_GAME` collision provider. Per-camera `cull_mask` isolation as
described above. This is the behavior the fork must match **with one shared data copy
instead of N**.

```gdscript
# Tier 1 spike — the contract to preserve, minus the per-node data duplication.
const GAMEPLAY_MASK: int = 0x0FFFF
const TERRAIN_TOP_BIT: int = 19   # player 0 → bit 19 (layer 20), descending

# Player 0 reuses the authored node (data + FULL_GAME collision untouched):
authored.render_layers = 1 << TERRAIN_TOP_BIT
authored.set_camera(player_cameras[0])
player_cameras[0].cull_mask = GAMEPLAY_MASK | (1 << TERRAIN_TOP_BIT)

# Players 1..N today get a fresh Terrain3D with its OWN data_directory (VRAM ×N).
# After the fork this whole loop collapses to a single authored.set_cameras([...]).
```

**Post-fork target (what the game will call instead):**

```gdscript
# One node, N cameras, one shared Terrain3DData. The game keeps its
# USE_PER_CAMERA_TERRAIN toggle wiring; only the call below changes.
authored.set_cameras(player_cameras)
for i in player_cameras.size():
    var bit := 1 << (TERRAIN_TOP_BIT - i)
    player_cameras[i].cull_mask = GAMEPLAY_MASK | bit
```

The game-side terrain entry points (for orientation — you won't edit these, they describe
the calls your API must satisfy):

- Each player's follow camera self-registers with Terrain3D in solo/online; in
  split-screen the game suppresses that (a flag, `register_terrain_camera = false`) and
  drives the terrain centrally instead.
- The stage's `_ready()` sets `collision_mode = FULL_GAME` on every terrain node and
  registers a parked fallback camera.
- Solo / online always pass a **single** camera — `set_cameras([one])` must behave
  exactly like today's `set_camera(one)`.

### 6. Upstream sync

- Record the base 1.0.1 commit; keep the diff small and isolated so rebasing onto future
  Terrain3D releases is cheap.
- Consider offering the change upstream against
  [#491](https://github.com/TokisanGames/Terrain3D/issues/491) — if accepted, Pasture3D
  becomes a thin/no layer and the fork can be deleted.

---

## Confirmed API symbols (1.0.1 binary audit)

These were verified present in the compiled GDExtension. Use them as the known-good base
the fork extends:

- `set_camera` / `get_camera` (single-camera center)
- `set_render_layers` / `get_render_layers` / `render_layers`
- `set_data` / `get_data` (`Terrain3DData`) — **note the blanking caveat above**
- `mesh_lods`, `mesh_size`, `vertex_spacing` (alias `mesh_vertex_spacing` in Inspector)
- `set_collision_mode` / `collision_mode` (`Terrain3DCollision.DISABLED`, `FULL_GAME`,
  `DYNAMIC_GAME`)
- `Terrain3DData.get_height` / `get_normal` / `region_size` / `get_region_count`,
  `collision_layer` / `collision_mask` / `collision_priority`
- `mouse_layer`, `cull_mask`, `render_cast_shadows`, `render_cull_margin`

Confirm exact property names in the 1.0.1 Inspector before relying on them; some have
Inspector aliases that differ from the setter name.

---

## Risks / open questions

- **Where exactly the snap + instance build live** in the 1.0.1 C++ (read the forked
  source; the role-based names in §3 are not verified symbols).
- **Shared data really shares GPU textures.** Validate at runtime that one
  `Terrain3DData` across N instance sets does **not** re-upload textures per set — this
  is the whole point. (Tier 1's `set_data` blanking shows the data classes assume single
  ownership; the fork must add a genuinely shared path, not just reuse `set_data`.)
- **Material/uniforms per instance set.** Confirm the shared material doesn't bake a
  single-camera assumption (e.g. a camera-position uniform). If it does, that uniform
  must become per-instance-set.
- **Editor behaviour.** The editor uses its own camera via `set_camera`; ensure the shim
  keeps editing/sculpting working.
- **Shadows.** One shadow pass for identical geometry should be correct for all
  viewports; validate no double-shadow / z-fight (§4).
- **Build/CI.** Multi-platform GDExtension builds are the real ongoing cost; confirm the
  toolchain reproduces a clean baseline before changing code.

---

## Checklist

- [ ] Fork Terrain3D at the 1.0.1 base commit; branch `pasture3d`; retain MIT + attribution
- [ ] Rebrand addon/library/`.gdextension` **and node classes** to `Pasture3D*`; keep
      `data_directory` format compatible so saved data re-points (roads as fallback)
- [ ] Stand up `godot-cpp` (4.6) + scons; **reproduce an unmodified baseline build first**
- [ ] Add `set_cameras()` / `get_cameras()`; make `set_camera()` a 1-element shim
- [ ] Generalize the clipmap to one mesh-instance-set per camera, **sharing one `Terrain3DData`**
- [ ] Per-camera render-layer tagging using the reserved top-4 scheme (layers 17–20);
      document the reserved range
- [ ] Keep one `FULL_GAME` collision on the node; cameras affect visual clipmap only
- [ ] Single shadow pass; validate no double-shadow
- [ ] Verify `set_cameras([one])` == today's `set_camera(one)` (solo/online unchanged)
- [ ] Cross-compile + smoke-test all shipped platforms (Windows x86_64 minimum)
- [ ] **Exit check:** 4-player split-screen — correct per-camera LOD **and VRAM ≈ single copy**
- [ ] Record base commit + rebase notes; consider upstreaming to #491

---

*Derived from Project Dead Sexy's internal planning docs (`docs/pasture3d_fork_guide.md`,
`docs/multi_camera_terrain_rendering_plan.md`, `docs/dynamic_multi_target_terrain_collision_plan.md`)
and the Tier 0/Tier 1 split-screen terrain spike (`SplitScreenTerrainCamera`,
`SplitScreenTerrainInstances`). Terrain3D 1.0.1 © Cory Petkovsek / Tokisan Games, MIT.*
