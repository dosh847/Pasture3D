# Pasture3D — Status & Continuation Guide

_Last updated: 2026-06-13. Read this first when resuming in a new session._

## Where things stand

Pasture3D is a fork of Terrain3D (TokisanGames), Godot 4.6, godot-cpp 4.5-stable
(`compatibility_minimum = 4.5`; binaries load on 4.6). Two pieces of work are **done and merged to
`main`** (commit `c68c95d`):

1. **Multi-camera clipmap** — one `Pasture3D` node renders one geo-clipmap per camera for local
   split-screen (2–4 players, one `World3D`), all sharing a single `Pasture3DData` (no VRAM ×N).
2. **Full Terrain3D → Pasture3D rebrand** — node/classes, addon folder, library, gdextension,
   editor plugin, GDScript tools, class docs, demo. Old terrain data still loads and migrates.

Branches `multi-camera-clipmap` and `rebrand-pasture3d` are merged and deleted (local + remote).
Only `main` remains. Working tree is clean.

## Repo layout (post-rebrand)

- Addon: `project/addons/pasture_3d/` — extension `pasture.gdextension`
  (`entry_symbol = "pasture_3d_init"`), library `bin/libpasture.*` (gitignored; build to produce).
- C++ sources: `src/pasture_3d*.{h,cpp}`. Classes: `Pasture3D`, `Pasture3DData`,
  `Pasture3DMaterial`, `Pasture3DAssets`, `Pasture3DRegion`, `Pasture3DCollision`,
  `Pasture3DInstancer`, `Pasture3DEditor`, `Pasture3DMeshAsset`, `Pasture3DTextureAsset`,
  `Pasture3DUtil`, plus `Pasture3DMesher` (internal).
- Class docs: `doc/doc_classes/Pasture3D*.xml`.
- Demo: `project/demo/Demo.tscn` (main scene); split-screen test `project/demo/SplitScreenTest.tscn`
  (launch with **F7** from the running demo, or F6 on the scene).

## Build

`scons` is not on PATH — use:

```
python -m SCons platform=windows target=editor arch=x86_64 -j8        # editor/debug -> libpasture.windows.debug.x86_64.dll
python -m SCons platform=windows target=template_release arch=x86_64 -j8  # release
```

Authoritative build: open `Pasture3D.sln` in Visual Studio 2022 (x64). Output lands in
`project/addons/pasture_3d/bin/`.

## Multi-camera API (the feature)

```gdscript
const GAMEPLAY_MASK := 0x0FFFF        # layers 1-16, every camera sees these
const TERRAIN_TOP_BIT := 19           # camera 0 -> layer 20, descending
terrain.collision_mode = Pasture3DCollision.FULL_GAME   # one shared collision, camera-independent
terrain.set_cameras(player_cameras)   # one clipmap per camera, one shared Pasture3DData
for i in player_cameras.size():
    player_cameras[i].cull_mask = GAMEPLAY_MASK | (1 << (TERRAIN_TOP_BIT - i))
```

- `set_cameras([one])` == `set_camera(one)` (single-view); editor/solo/online unchanged.
- Reserved render layers 17–20 (one per player). Keep gameplay on layers 1–16.
- Per-camera LOD geomorph works because `_target_pos` in `src/shaders/main.glsl` is an
  `instance uniform`, set per view in `Pasture3DMesher::snap()`.
- Shadows cast from one view only. Collision stays single FULL_GAME.
- Limitation: with `tessellation_level > 0` the displacement buffer follows camera 0 only — use
  `tessellation_level = 0` for split-screen.

## Terrain data backward-compatibility

Old `terrain3d_*.res` (embedded class `Terrain3DRegion`) still loads via compatibility subclasses
(`src/pasture_3d_compat.h`, registered in `register_types.cpp`). On load, legacy regions are
re-classed to `Pasture3DRegion`, marked modified, and **re-saved as `pasture3d_*.res`** (old file
removed). Same compat aliases exist for Material/Assets/Mesh/TextureAsset. So: open an old map →
save → it's migrated. (Verified working in the editor.)

## Remaining / follow-up work (none blocking)

- **VRAM proof:** split-screen renders correctly; confirm "4 views ≈ one Pasture3DData" in a GPU
  profiler (the headline claim) — not yet quantitatively measured.
- **Other platforms:** only Windows x64 built/verified. Build Linux/macOS if shipping them
  (declared in `pasture.gdextension`).
- **C# bindings:** `project/addons/pasture_3d/csharp/Terrain3D*.cs` still have old *filenames*
  (class names inside are `Pasture3D*`; they work because C# resolves by class, not filename).
  Cosmetic rename pending.
- **`.github/workflows/*.yml`:** CI artifact names still say `libterrain` — only matters if using
  GitHub Actions builds.
- **Prose docs:** `doc/docs/**` readthedocs, `README.md`, `AUTHORS.md`, `CONTRIBUTING.md` still say
  "Terrain3D" (left intact to preserve attribution; rebrand separately).
- **Game integration:** Project Dead Sexy swaps `addons/terrain_3d` → `addons/pasture_3d` and calls
  `set_cameras(...)` — that work is in the game repo, not here.

## Reference docs in-repo

- `PASTURE3D_PLUGIN_FORK_GUIDE.md` — original design/mission.
- `PASTURE3D_IMPLEMENTATION_PROGRESS.md` — multi-camera checklist + how to test.
- `PASTURE3D_REBRAND_PROGRESS.md` — rebrand checklist + data-compat approach.
