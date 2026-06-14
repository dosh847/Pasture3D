# Pasture3D — Rebrand Progress (Terrain3D → Pasture3D)

> Resumable checklist for the full rebrand. Branch `rebrand-pasture3d` (based on
> `multi-camera-clipmap`). If interrupted, read this + `PASTURE3D_PLUGIN_FORK_GUIDE.md`.

**Goal:** rename Terrain3D → Pasture3D everywhere (node class, all classes, addon folder,
library `libpasture.*`, `pasture.gdextension`, entry symbol `pasture_3d_init`, editor plugin,
GDScript tools, docs, demo) **while keeping existing saved terrain data loadable**.

**Data-compat strategy (user requirement):** new saves use `Pasture3DRegion` / `pasture3d_*.res`,
but old `terrain3d_*.res` (embedded class `Terrain3DRegion`) must still load. Done via
**compatibility subclasses**: `class Terrain3DRegion : public Pasture3DRegion {}` (and same for
the other serialized resources), registered so old files deserialize; region loader scans both
globs; a load→save migrates old files to the new class + filename.

**Three token forms (case-sensitive):**
`Terrain3D`→`Pasture3D`, `terrain_3d`→`pasture_3d`, `terrain3d`→`pasture3d`.

## Checklist

- [x] **R0** Branch `rebrand-pasture3d` created
- [x] **R1** C++ mass rename (src/*.{h,cpp,glsl}) — 3 tokens + uppercase guards
- [x] **R2** Rename src files terrain_3d* → pasture_3d*; update includes; .vcxproj content + file renamed
- [x] **R3** Compat subclasses (Region/Material/Assets/MeshAsset/TextureAsset) in pasture_3d_compat.h + registered. (Data is an Object, never serialized → no compat needed.)
- [x] **R4** Region loader scans both globs; filename_to_location handles both prefixes; legacy regions re-classed to Pasture3DRegion, marked modified, legacy file removed on save
- [x] **R5** Build config: addon folder → pasture_3d, pasture.gdextension (entry_symbol/libpasture/icon), plugin.cfg, SConstruct glob, OCEAN_MATERIAL_PATH, .gitignore bin path
- [x] **R6** GDScript editor tools: class refs + `res://addons/pasture_3d/` paths (+ .gdshaderinc)
- [x] **R7** Docs: doc/doc_classes/Terrain3D*.xml renamed to Pasture3D*.xml + content
- [x] **R8** Demo + SplitScreenTest: scene type refs, .tres types, paths
- [x] **R9** Build: libpasture.windows.debug (2.15 MB) + template_release both link clean
- [ ] **R10** Self-review done; commit + PR. Runtime verify (Godot 4.6) = USER (load old map, save → pasture3d_*.res; addon enables; demo runs)

## Out of scope (follow-ups, do not block)

- `.github/workflows/*.yml` (CI artifact names still libterrain) — local VS/scons build unaffected.
- `doc/docs/**` readthedocs prose (.rst/.md), `README.md`, `AUTHORS.md`, `CONTRIBUTING.md` — left to
  preserve attribution; rebrand prose separately.
- Intentional legacy references remain (correct): `Terrain3D*` compat classes in
  `pasture_3d_compat.h` + `register_types.cpp`; `"terrain3d"` legacy glob/prefix in
  `pasture_3d_data.cpp` and `pasture_3d_util.cpp`.

## Notes / log

- (start) Based on multi-camera-clipmap @ d36c194. godot-cpp 4.5-stable.
- Region .res are binary (RSCC header) embedding class name; loaded via ResourceLoader.load(path,
  "Terrain3DRegion", ...) in terrain_3d_data.cpp load_directory/load_region.
- location_to_filename builds "terrain3d"+loc+".res"; filename_to_location trims "terrain3d".
- Source filenames WILL be renamed (terrain_3d*.h → pasture_3d*.h) for include consistency.
- LICENSE.txt / AUTHORS.md / README.md / root *.md left untouched (retain MIT attribution).
