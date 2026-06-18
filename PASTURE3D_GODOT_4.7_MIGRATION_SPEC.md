# Pasture3D — Godot 4.7 Migration Spec

**Branch:** `godot-4.7-migration`
**Date:** 2026-06-18
**Author:** Migration review (5-section audit of the full plugin against the official
[Upgrading to Godot 4.7](https://docs.godotengine.org/en/4.7/tutorials/migrating/upgrading_to_godot_4.7.html) guide)

---

## 0. Executive summary

Pasture3D is a native **GDExtension** plugin (C++ fork of Terrain3D, built with `godot-cpp`).
The whole `src/` tree (36 C++ files, 14 GLSL shaders), build system, project, demos, docs and
unit tests were reviewed against the complete 4.6 → 4.7 breaking-change list.

**Bottom line: this is a low-risk migration with zero *required* source edits.** Every changed
Godot API that Pasture3D actually calls is **source-compatible** in 4.7 (the breaking parts are
appended-optional parameters or implicit `StringName` conversions). The migration is dominated by
three mechanical actions plus verification:

1. Bump the `godot-cpp` submodule to the **4.7** release line and do a **clean rebuild**.
2. Bump three version strings (`compatibility_minimum`, `config/features`, .NET SDK).
3. Verify (compile, load in 4.7 editor, run the layer unit-test suite, visual smoke tests).

### ⚠️ Important discovery — the repo is on 4.5, not 4.6

The task was framed as "4.6 → 4.7", but the tree is actually building against **4.5** bindings:

| Marker | Current value | Reality |
|---|---|---|
| `godot-cpp` submodule pin | `godot-4.5-stable-27-g60b5a41` | 4.5 ABI |
| `godot-cpp/gdextension/extension_api.json` | `version_major 4, version_minor 5` | 4.5 |
| `project/addons/pasture_3d/pasture.gdextension` | `compatibility_minimum = 4.5` | 4.5 |
| `project/project.godot` | `config/features=("4.6")` | claims 4.6 |
| `project/Pasture3D.csproj` | `Godot.NET.Sdk/4.6.3` | claims 4.6 |

**Consequence:** moving to 4.7 also crosses the **4.5 → 4.6** delta, not just 4.6 → 4.7. The 4.6 → 4.7
review below found nothing blocking; a quick pass of the
[4.5 → 4.6 upgrade guide](https://docs.godotengine.org/en/4.6/tutorials/migrating/upgrading_to_godot_4.6.html)
should be done as well before declaring done (see §6, Open Question 1). In practice, since the only
4.7-affected APIs the plugin touches are all backward-compatible, the same is very likely true of the
4.5 → 4.6 delta — but it must be confirmed, not assumed.

---

## 1. Migration phases

### Phase A — Toolchain bump (BLOCKER, do first)

1. **Update godot-cpp to 4.7.**
   ```sh
   git -C godot-cpp fetch --tags origin
   git -C godot-cpp checkout godot-4.7-stable      # or the godot-4.7 maintenance branch
   git add godot-cpp
   ```
   - The local submodule clone has **not** been fetched recently (`git -C godot-cpp describe` only
     knew the 4.5 tag) — run the `fetch --tags` first.
   - Optionally update `.gitmodules`: `branch = master` → `branch = 4.7`, so
     `git submodule update --remote` tracks the 4.7 line instead of bleeding-edge master.
   - godot-cpp regenerates its bindings from the bundled `extension_api.json` + `gdextension_interface.h`
     at build time, so **no manual binding regen** is needed — but a full rebuild is.

2. **Clean rebuild against 4.7.**
   - The build is `python -m SCons` (scons is not on PATH).
   - **Delete stale objects first** — the tree contains `.obj` files built against the old ABI,
     including leftover `src/terrain_3d_*.obj` from before the rebrand. Run `scons --clean` (or delete
     `src/*.obj`) before rebuilding, or the link step will mix 4.5 and 4.7 objects.
   - Build all required targets (`target=editor`, `target=template_release`, etc.).

### Phase B — Config version bumps (BLOCKER)

| File | Line | From | To |
|---|---|---|---|
| `project/addons/pasture_3d/pasture.gdextension` | 4 | `compatibility_minimum = 4.5` | `compatibility_minimum = 4.7` |
| `project/project.godot` | 19 | `config/features=PackedStringArray("4.6")` | `config/features=PackedStringArray("4.7")` |
| `project/Pasture3D.csproj` | 1 | `<Project Sdk="Godot.NET.Sdk/4.6.3">` | `<Project Sdk="Godot.NET.Sdk/4.7.x">` (match released 4.7 .NET SDK) |

- `entry_symbol = "pasture_3d_init"` matches `register_types.cpp:51` — **no change**.
- Confirm whether 4.7's `Godot.NET.Sdk` still targets `net8.0` (csproj line 3) or moves to `net9.0`.

### Phase C — Source code (NO required changes)

The full audit found **zero source edits required to compile or run correctly under 4.7.**
See §2 for the affected-API inventory and §3 for the recommended (optional) hardening edits.

### Phase D — Verification (see §5)

---

## 2. Affected-API inventory (everything the plugin actually touches)

Every 4.7-changed API found anywhere in `src/`. All are **source-compatible** — listed so each is
consciously verified, not skipped.

| file:line | API | 4.7 change | Impact | Action |
|---|---|---|---|---|
| `src/pasture_3d_data.cpp:2004` | `Image::save_exr(path, grayscale)` | gains optional `color_image`, `max_linear_value` (appended) | Existing 2-arg call still binds; `grayscale` stays 2nd positional | Recompile; one-time EXR heightmap round-trip check |
| `src/pasture_3d_assets.cpp:405, 638` | `RenderingServer::viewport_set_size(vp, w, h)` | gains optional `view_count` (appended) | 2-arg call still binds | Recompile; confirm no deprecation warning |
| `src/pasture_3d_mesh_asset.cpp:282` | `Object::is_class("MeshInstance3D")` | param `String` → `StringName` | String literal implicitly converts to `StringName` | Recompile only |

**Not affected (explicitly checked):**

- **`get_format()` relocation** (`ImageTexture`/`PortableCompressedTexture2D` → base `Texture2D`):
  every `get_format()` call in the plugin is on `Ref<Image>` (`Image::get_format()` is unchanged),
  not on a texture class. ~13 call sites across `data.cpp`, `region.cpp`, `util.cpp`,
  `generated_texture.cpp`, `assets.cpp` — all safe.
- **`ZIPPacker::start_file()`** — not used anywhere in plugin code (only appears in the generated
  `extension_api.json`).
- **`RenderingServer::particles_request_process_time` / particles `request_particles_process`** — no
  particle APIs used.
- **InputEvent device IDs (mouse/keyboard `0` → named constants)** — no raw `InputEvent` device-ID
  handling in C++; input arrives pre-digested from the GDScript editor plugin as a `Dictionary`.
- **`CanvasItem` line-draw AA-feather removal** — no `draw_line`/`draw_polyline`/CanvasItem overlay
  calls in C++ (grids/overlays are drawn by the GDScript editor layer + shaders).
- **Physics / Jolt changes** (one-way collision `direction`, `WorldBoundaryShape3D.plane.d` sign,
  `SoftBody3D` defaults, Area3D↔SoftBody overlaps): the plugin only uses `HeightMapShape3D` +
  `body_*` calls, none of which changed. One-way collision is **2D-only** in the 4.7 change. (`body_add_shape`
  signature confirmed unchanged.)
- **Editor `*Extension` virtuals** (`EditorVCSInterface::_commit`, `EditorSceneFormatImporter` import
  flags, OpenXR, `PhysicsServer2DExtension`): none of these base classes are extended. All plugin
  classes derive from `Node3D` / `Object` / `Resource` and override only `_bind_methods`,
  `_notification`, `_validate_property`, `_property_can_revert`, `_property_get_revert`,
  `_get_configuration_warnings` — none of which gained required params in 4.7.
- **GDScript behavior changes** (packed-array element assignment no longer triggers setters;
  typed-return methods now need explicit `return`): no occurrences in any demo `.gd` or `.tscn`.
  All typed-return functions already return on every path; pixel writes use `Image.set_pixel(...)`
  method calls, not packed-array element-setter assignment.
- **`AudioStreamPlayer.area_mask` 1→0 default** — no `AudioStreamPlayer` in any demo scene.

### Virtual-override safety note

The most dangerous class of 4.7 change for native plugins is "+REQUIRED parameter" added to a
`*Extension` virtual — these silently fail to dispatch if an override signature no longer matches.
**Audit result: none apply.** Pasture3D registers only plain `Pasture3D*` nodes/resources
(`register_types.cpp:20-39`) and extends no `*Extension` base. Recommend a final repo-wide grep for
`override` after the bump to confirm no signature drift, but no offenders exist today.

---

## 3. Recommended (optional) hardening — not required for 4.7

These improve safety/correctness but are not gated by the migration:

1. **`src/pasture_3d.h:352`** — `_validate_property(PropertyInfo &) const` is declared **without**
   `override`. It works, but adding `override` makes any *future* godot-cpp virtual-signature change a
   loud compile error instead of a silent non-override. Low effort, recommended.
2. Run a repo-wide `override` audit after the bump (see §2 note).

---

## 4. Pre-existing issues to fix alongside the bump (rebrand drift, not 4.7-specific)

These are already broken from the Terrain3D → Pasture3D rebrand. A clean 4.7 build is a good moment to
fix them so the migration also yields a valid, packageable artifact:

| File | Issue | Severity |
|---|---|---|
| `.github/workflows/build.yml` (~lines 102-120) | Strip/Prepare steps still reference `terrain_3d` addon dir and `libterrain.*` lib names — artifact packaging is broken | MED |
| `Pasture3D.vcxproj:224` | `<None Include="...terrain.gdextension">` points at a file that was renamed to `pasture.gdextension` (dead reference) | LOW |
| `doc/docs/*` and `doc/api/class_terrain3d*.rst` | Docs still use `Terrain3D`/`terrain3d` class names and links; don't match the `Pasture3D*` symbols | LOW |
| `src/*.obj`, `src/terrain_3d_*.obj` | Stale pre-rebrand/pre-4.7 object files committed in `src/` | HIGH (clean before rebuild) |

There is also **no CI smoke test** that loads the built extension in an actual editor — so an ABI
mismatch (the exact failure mode of skipping the submodule bump) would not be caught by CI. Consider
adding a headless 4.7 load test.

---

## 5. Verification checklist

After Phases A–C:

- [ ] `scons --clean` then full rebuild against godot-cpp 4.7 succeeds for all targets, **no warnings**
      on the three affected APIs in §2.
- [ ] Extension loads in a **Godot 4.7** editor with no "incompatible / could not load" errors
      (validates `compatibility_minimum` and ABI).
- [ ] **Layer unit tests** pass — re-enable the calls in `src/pasture_3d.cpp:1240-1249`
      (`test_layer_compositing`, `test_layer_idempotent_composite`, `test_layer_subtiling`,
      `test_layer_control_color` are the byte-parity tests that would catch any RF/RGF/RGBA8 in-memory
      packing change). Decide whether to re-enable `test_layer_stroke_undo_integration` (disabled in
      commit `2278ec3`).
- [ ] **EXR heightmap round-trip**: export a height map (`save_exr` grayscale path) and confirm it reads
      back identically (the one place where 4.7 changed defaults, though single-channel `FORMAT_RF`
      should be unaffected).
- [ ] **Mesh thumbnails**: open the Asset Dock; confirm mesh thumbnails still render (the RS-heavy
      `viewport`/`scenario` path in `pasture_3d_assets.cpp` — not covered by unit tests).
- [ ] **Visual smoke test on all three renderers** (Forward+, Mobile, Compatibility):
  - Wet/low-roughness terrain reflections — `roughness_layers` default changed 7→8, a global engine
    change that subtly affects sky specular sharpness (the material reads `SPECULAR = 1. - roughness`,
    `pbr_views.glsl:64`). Not a bug, but expect minor reflection differences.
  - `gpu_depth.glsl` displacement/depth buffer (toggle the displacement debug view) — the most
    version-sensitive shader (depth reconstruction, `RENDERER_COMPATIBILITY` branch).
- [ ] Run the five demo scenes (`Demo`, `CodeGeneratedDemo`, `NavigationDemo`, `sculpting_demo`,
      `SplitScreenTest`).

---

## 6. Open questions / risks

1. **4.5 → 4.6 delta.** The repo is on 4.5 bindings, so the jump to 4.7 also crosses 4.5 → 4.6. This
   spec covers 4.6 → 4.7 exhaustively; do a confirming pass over the 4.5 → 4.6 guide. (Expected to be
   clean given the same APIs are all backward-compatible, but verify.)
2. **godot-cpp 4.7 tag availability** at migration time — confirm `godot-4.7-stable` (or the 4.7 branch)
   exists and is the intended pin; `fetch --tags` the submodule first.
3. **.NET target framework** — does 4.7's `Godot.NET.Sdk` still target `net8.0`, or move to `net9.0`?
   `Pasture3D.csproj` hardcodes `net8.0` (line 3).
4. **GDScript editor plugin** — the real 4.7 input/overlay/EditorPlugin exposure lives in the GDScript
   `editor_plugin.gd` (raw `InputEvent` device IDs, `_forward_3d_gui_input`, `_handles`, undo/redo
   `create_undo_action`/`commit_action` called from `pasture_3d_editor.cpp:706-713`, viewport `draw_*`
   overlays), which is **outside `src/`** and was not part of this C++ audit. It should be reviewed
   against the 4.7 EditorPlugin/InputEvent changes separately.
5. **Jolt backend** — if Jolt is the active 3D physics backend, sanity-test the negative-value
   bounce/friction encoding at `pasture_3d_collision.cpp:204-210` at runtime (Jolt historically
   interprets material param sign conventions differently than Godot Physics).

---

## Appendix — review coverage map

| Section | Files reviewed | Result |
|---|---|---|
| 1. Build & integration | godot-cpp pin, SConstruct, .gdextension, project.godot, csproj/sln/vcxproj, register_types, constants.h, compat.h, CI, docs | 2 BLOCKER config bumps + submodule bump; rebrand drift |
| 2. Core terrain engine | pasture_3d.cpp/.h, data.cpp/.h, region, util, target_node_3d, generated_texture, logger | 0 blockers; `save_exr` (compat) |
| 3. Material + shaders | pasture_3d_material.cpp/.h, all 14 GLSL shaders | 0 blockers; `roughness_layers` visual note |
| 4. Editor/collision/mesher/instancer | editor, collision, mesher, instancer (+docs) | 0 blockers; no input/draw/physics hits in C++ |
| 5. Assets/layers/tests/docs/demos | assets, mesh_asset, texture_asset, layer, layer_stack, unit_testing, demos, docs | 0 blockers; no GDScript breaking patterns |
