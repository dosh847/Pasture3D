# Pasture3D — Multi-Camera Implementation Progress

> Resumable checklist for the multi-camera geo-clipmap fork. If work is interrupted, read this
> file + `PASTURE3D_PLUGIN_FORK_GUIDE.md` + the plan
> (`~/.claude/plans/distributed-soaring-minsky.md`) to resume. Check items off as completed.

**Goal:** one `Terrain3D` node renders one clipmap per camera (`set_cameras([...])`) at correct
per-camera LOD, sharing a single `Terrain3DData` (no VRAM ×N). Collision stays single FULL_GAME.

**Locked decisions:** (1) multi-camera first, rebrand deferred; (2) keep godot-cpp 4.5-stable,
compat_min 4.5 (runs on Godot 4.6); (3) attempt local scons/MSVC compile, authoritative build is
user's VS2022.

## Checklist

- [x] **B0** Install scons; baseline `target=editor` build succeeds (clean toolchain) — DLL @ 2.1 MB
- [x] **S1** `src/shaders/main.glsl`: `_target_pos` → `instance uniform`
- [x] **M1** Mesher: add `ClipmapView` struct + `_views`, `_uses_instance_target_pos`
- [x] **M2** Mesher: `_generate_view_instances` / `_clear_views` over all views (+ flat `instance_rids`)
- [x] **M3** Mesher: `set_views()`; `initialize()` takes instance-target-pos flag, seeds 1 view
- [x] **M4** Mesher: `snap()` per-view target + per-instance `_target_pos` (terrain) / material (ocean)
- [x] **M5** Mesher: `update()` per-view layers + shadow-caster-once
- [x] **N1** Node: `_cameras`, `set_cameras`/`get_cameras`, `set_camera` reconciliation
- [x] **N2** Node: `_setup_terrain_mesher` passes flag + re-applies cameras; bindings added
- [x] **B1** Both `target=editor` (debug, 2.14 MB) and `target=template_release` (1.44 MB) build clean
- [x] **D1** Doc: `Terrain3D.xml` set_cameras/get_cameras + reserved layer range (17–20)
- [ ] **V1** Runtime/VRAM exit check — USER, in Godot 4.6 + game (see "How to test" below)

## How to test (user, in Godot 4.6)

Build is reproducible here via `python -m SCons platform=windows target=editor arch=x86_64`
(authoritative build = your VS2022: open `Terrain3D.sln`, build x64). Output DLL lands in
`project/addons/terrain_3d/bin/`.

**Ready-to-run scene:** `project/demo/SplitScreenTest.tscn` (script `demo/src/SplitScreenTest.gd`).
Two ways to launch:
- Run the main demo (`Demo.tscn`, F5) and press **F7** (wired into the demo UI; F7/Esc returns,
  F8 quits).
- Or open `SplitScreenTest.tscn` and press **F6** (Run Current Scene).

It builds a 2x2 split-screen: 4 SubViewports sharing one World3D + one Terrain3D, one orbiting
camera each via `set_cameras()`, plus four colored "kart" markers on gameplay layers visible in
every quadrant, and an on-screen instructions overlay. Edit `PLAYER_COUNT` (2-4) to vary players.
Watch each quadrant keep high-detail terrain around its own player as they separate; confirm one
shared Terrain3DData in your GPU/VRAM profiler.

1. **Editor / solo (regression):** open `project/` in Godot 4.6, sculpt/paint, fly around — single
   clipmap behavior must be identical to before. `set_camera(cam)` and `set_cameras([cam])` both =
   single view.
2. **Split-screen:** 2–4 `SubViewport`s, each with its own `Camera3D`, all sharing one `World3D`
   and one `Terrain3D`:
   ```gdscript
   const GAMEPLAY_MASK := 0x0FFFF          # layers 1-16, seen by every camera
   const TERRAIN_TOP_BIT := 19             # cam 0 → layer 20, descending
   terrain.collision_mode = Terrain3DCollision.FULL_GAME   # single, camera-independent
   terrain.set_cameras(player_cameras)     # one shared Terrain3DData, one clipmap per camera
   for i in player_cameras.size():
       player_cameras[i].cull_mask = GAMEPLAY_MASK | (1 << (TERRAIN_TOP_BIT - i))
   ```
   Confirm: each viewport shows correct LOD around its own player; no large triangles snapping
   through karts on the non-tracked players; no one falls through; no double shadows.
3. **Exit check:** 4-player split-screen — correct per-camera LOD AND VRAM ≈ a single Terrain3DData
   (compare against the Tier 1 N-node build).

## Notes / log

## Notes / log

- (start) Repo is at HEAD ff4614c, 297 commits past v1.0.1; godot-cpp submodule @ 4.5-stable.
- Per-camera `_target_pos` handled via Godot `instance uniform` + `instance_geometry_set_shader_parameter`.
- Ocean mesher stays single-view (separate material, normal `_target_pos` uniform).
- Tessellation displacement buffer stays single-target (documented limitation).
- (impl) Mesher refactored to N `ClipmapView`s sharing `_mesh_rids` + material; node gained
  `_cameras` + `set_cameras`/`get_cameras`; shader `_target_pos` is now `instance uniform`.
  Files: `src/terrain_3d_mesher.{h,cpp}`, `src/terrain_3d.{h,cpp}`, `src/shaders/main.glsl`,
  `doc/doc_classes/Terrain3D.xml`. C++ compiles clean (editor target linked OK).
- (only unverifiable-here risk) Godot must accept `instance uniform vec3 _target_pos = vec3(0.f);`
  at shader load. Defaults on instance uniforms are supported in Godot 4.x; if a load error appears,
  drop the `= vec3(0.f)` default (C++ always sets the value per instance anyway).
