# Pasture3D Layers — Phase 3 (Persistence) handoff

Start-here brief for a new session implementing **Phase 3** of
[`PASTURE3D_LAYERS_GUIDE.md`](PASTURE3D_LAYERS_GUIDE.md). Read guide §7 (Persistence &
migration) and §11.1 (settled file-granularity decision) first; this doc tells you exactly
where the code stands and what to build next.

Repo: `F:\LaughingRooster\GodotExtensions\Pasture3D` · branch `pasture3d-layers`.

---

## Build, test, run

```powershell
# Build (scons is not on PATH — invoke via python). Source globs from src/*.cpp automatically.
python -m SCons platform=windows target=editor arch=x86_64 -j8

# Run the in-engine test suite headlessly (Godot 4.6.2):
#   1. In src/pasture_3d.cpp NOTIFICATION_READY, uncomment the test call(s):
#        //test_layer_compositing();   ->   test_layer_compositing();
#   2. Rebuild, then:
& "F:\ProjectDeadSexy\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" `
    --headless --path "F:\LaughingRooster\GodotExtensions\Pasture3D\project" --quit-after 30
#   3. Grep stdout for "PASSED"/"FAILED". RE-COMMENT the call before committing (keeps main shippable).
```

Test scaffolding is `src/unit_testing.{h,cpp}` — free functions using `EXPECT_TRUE/EXPECT_FALSE`
that print `PASSED:`/`FAILED:`. They are invoked (commented-out) from `Pasture3D` `NOTIFICATION_READY`
in `src/pasture_3d.cpp`. `unit_testing.h` is already `#include`d at the top of `pasture_3d.cpp`.

---

## What exists now (Phases 1 & 2 — done, do not rebuild)

### Phase 1 — data model
- **`Pasture3DLayer : Resource`** (`src/pasture_3d_layer.{h,cpp}`, bound, doc XML present).
  - `enum BlendMode { REPLACE, ADD, MAX, MIN, BLEND_MAX }` — only the first four have semantics;
    `BLEND_MAX` is an undefined placeholder.
  - Metadata: `name, blend, opacity, visible, locked, reserved, owner_id, map_type` (v1 = `TYPE_HEIGHT`),
    `tile_size`.
  - Sparse pixel store `_tiles[region_loc:Vector2i] -> Dict[tile_coord:Vector2i] -> Ref<Image>`
    (FORMAT_RGF, R=value G=weight). Runs with `tile_size == region_size` (one tile/region) for now.
  - **Serialization already implemented**: `get_data()/set_data()` return/accept a `Dictionary`
    with keys `name, blend_mode, opacity, visible, locked, reserved, owner_id, map_type, tile_size,
    tiles`. Also `get_tiles()/set_tiles()`.
- **`Pasture3DLayerStack : Resource`** (`src/pasture_3d_layer_stack.{h,cpp}`, bound, doc XML present).
  - Ordered `_layers` (index 0 = Base, protected), `_active_layer`, `_version`
    (`CURRENT_STACK_VERSION = 0.1f`).
  - `add_layer/add_layer_ref/remove_layer/move_layer/get_layer(_ptr)/find_layer_by_owner/
    get/set_active_layer`.
  - **Serialization already implemented**: `get_data()/set_data()` → `Dictionary{ version, layers }`
    where `layers` is the `TypedArray<Pasture3DLayer>`.
- **`Pasture3DData`** holds `Ref<Pasture3DLayerStack> _layer_stack`
  (`has_/get_/set_layer_stack`). `load_directory()` calls private `_synthesize_base_layer()`,
  which builds a 1-layer stack whose dense Base layer **aliases** each region's `_height_map`
  (FORMAT_RF, zero-copy) via `set_region_image`.

### Phase 2 — compositing
- `Pasture3DData::composite_region(region_loc, dirty_rect = Rect2i(), update = true)` and
  `composite_regions()` in `src/pasture_3d_data.cpp` (bound to GDScript). Walk layers bottom→top,
  skip hidden/uncovered (`weight==0`), apply REPLACE/ADD/MAX/MIN with `a = weight*opacity`, write
  into the region `_height_map`; `set_edited(true)` + `update_maps(TYPE_HEIGHT, all_regions=false)`.
  No stack ⇒ no-op (runtime path unchanged, zero added cost).
- `test_layer_compositing()` in `src/unit_testing.cpp` verifies the guide §10.2 acceptance:
  **Base-only composite is byte-identical** to the input height map, plus an ADD-layer sanity check.
  All 4 assertions PASSED when run headlessly.

### ⚠ Critical cross-cutting finding — Base-layer aliasing (read this before designing save/load)
The Base layer **aliases** the region `_height_map` image (same `Ref<Image>`), and
`composite_region` writes its result back into that same image. A single composite pass is correct
(read-before-write per pixel; identity holds), **but re-compositing the same region repeatedly with
ADD/MAX/MIN layers double-applies the deltas.** See the ⚠ note added to guide §5.1.

**Implication for Phase 3 persistence — do NOT serialize the Base layer's pixel tiles.** The Base
data *is* the region height maps, which already persist as `pasture3d_<loc>.res`. On load, the Base
must be **re-aliased onto the freshly-loaded region images** (exactly like `_synthesize_base_layer`),
never restored from a stale copy in a layer file. Persist Base **metadata only**; persist pixel
tiles for layers 1..n only. This keeps layer files small, keeps the runtime `.res` authoritative,
and sidesteps the aliasing trap.

---

## Phase 3 goal

Save/load the editor-side layer stack as `pasture3d_layers*.res` files, **without touching the
runtime `pasture3d_<loc>.res` path**. A build with no layer files must remain byte-identical in the
runtime region files and must still open (falling back to `_synthesize_base_layer`).

### Binding decision (guide §11.1): manifest + per-region
- `pasture3d_layers.res` — **manifest**: ordered layer *metadata* (name, blend, opacity, flags,
  owner_id, map_type, tile_size), `_version`, layer order/count. No pixels.
- `pasture3d_layers_<loc>.res` — **per-region pixel slice**: for each non-Base layer, that layer's
  sparse tiles that fall in `<loc>` (i.e. the inner `Dict[tile_coord -> Image]` from
  `layer._tiles[loc]`).

A single-file form (everything in one `pasture3d_layers.res`) is allowed by §11.1 **only as a
throwaway prototype**; the per-region split is the binding target. Recommend implementing the split
directly — the data is already shaped for it (`layer._tiles` is keyed by region_loc).

---

## Suggested implementation plan

All work is in `src/pasture_3d_data.cpp` (+ small helpers possibly on the stack/layer). Reuse the
existing region I/O patterns.

### Filenames — reuse `Pasture3DUtil` (`src/pasture_3d_util.cpp`)
- `location_to_string(loc)` → e.g. `-01_02`; `location_to_filename(loc)` → `pasture3d-01_02.res`.
- `string_to_location` / `filename_to_location`; `get_files(dir, glob)` (matches with `matchn`,
  strips `.remap`).
- Add `pasture3d_layers.res` (literal) for the manifest and
  `"pasture3d_layers" + location_to_string(loc) + ".res"` for per-region slices. Consider a
  `location_to_layer_filename(loc)` helper next to `location_to_filename`.

### Save (`save_directory`, currently `pasture_3d_data.cpp:332`)
Per guide §7.2:
1. `composite_regions()` first (ensure region images are current — cheap no-op if nothing edited).
2. Existing loop: `save_region(...)` → `pasture3d_<loc>.res` (UNCHANGED; this is the runtime data).
3. If `has_layer_stack()`:
   - Write the **manifest**: build a metadata-only view. Easiest robust approach: duplicate the
     stack, and for each layer store `get_data()` **with `tiles` removed** (or add a
     `get_metadata()`/`get_manifest()` that omits tiles). Save via
     `ResourceSaver::get_singleton()->save(stack_or_wrapper, dir + "/pasture3d_layers.res",
     FLAG_COMPRESS)` — mirror `Pasture3DRegion::save` (`pasture_3d_region.cpp:296`,
     uses `ResourceSaver` + `take_over_path`).
   - For each region loc, write a **per-region slice** containing, for each non-Base layer index,
     `layer.get_tile`/`layer._tiles[loc]`. **Skip layer 0 (Base).** Skip locs/layers with no tiles
     so files stay sparse. A simple container is a `Dictionary{ layer_index -> inner_tile_dict }`
     wrapped in a tiny `Resource`, or reuse a stack-like resource.
   - Add `_version` to the manifest (already on the stack: `CURRENT_STACK_VERSION`) for future
     upgrades, à la `Pasture3DRegion::_version`.

A game build ships only `pasture3d_<loc>.res` and omits `*_layers*` — nothing to strip, no runtime
branch.

### Load (`load_directory`, currently `pasture_3d_data.cpp:391`; Base synth at `:456`)
Per guide §7.3:
1. Load `pasture3d_<loc>.res` as today → composited region images; `update_maps(TYPE_MAX, true)`.
2. **If `pasture3d_layers.res` exists**: load the manifest (rebuild ordered layers + metadata), then
   load each `pasture3d_layers_<loc>.res` and merge its tiles back into the matching layers'
   `_tiles[loc]`. Then **re-alias the Base layer onto the loaded region images** (call the same
   logic as `_synthesize_base_layer`, but populate Base only — keep the loaded upper layers).
   Finally `composite_regions()` so the region images reflect the full stack (or trust the saved
   region images if you guarantee save always composited — but a guard recomposite is safer; mind
   the aliasing caveat — a single pass is fine).
3. **Else**: current behavior — `_synthesize_base_layer()` (single Base-only stack).

> Note `load_region()` (`:460`) loads one region; if you support per-region streaming, also load
> that region's `pasture3d_layers_<loc>.res` slice there.

### Bindings
Bind any new public methods (e.g. a `save_layers`/`load_layers` if you expose them) in
`Pasture3DData::_bind_methods` (`pasture_3d_data.cpp:1266`), matching the existing `D_METHOD`/`DEFVAL`
style. `save_directory`/`load_directory` are already bound.

---

## Acceptance tests (add to `src/unit_testing.cpp`, guide §10 phase 3)

1. **Runtime files unchanged.** After adding a layer stack and `save_directory`, the
   `pasture3d_<loc>.res` bytes are identical to a save with no stack (the layer feature must not
   perturb runtime data). The Phase 2 identity test already proves composite-into-Base is identity;
   extend to a save round-trip.
2. **Stack round-trip.** Build a stack (Base + one ADD layer with a few tiles), save, clear, load,
   and assert layer count, per-layer metadata, and a sampled `(value, weight)` survive; and that the
   Base layer is re-aliased to the loaded region image (not a copy) — e.g. editing the region image
   is reflected via `get_layer(0).get_value`.
3. **No-layer-files load.** A directory with only `pasture3d_<loc>.res` (no `*_layers*`) loads and
   synthesizes a single Base layer (existing path), unchanged.

Follow the Phase 2 test's pattern: a standalone `memnew(Pasture3DData)` + `add_region(region, false)`
avoids needing a `Pasture3D` node / RenderingServer. For file I/O tests, write to `user://` or a temp
dir via `DirAccess`.

---

## Files you'll likely touch

| File | Why |
|---|---|
| `src/pasture_3d_data.cpp` (+ `.h`) | `save_directory`/`load_directory` extensions, bindings |
| `src/pasture_3d_util.{h,cpp}` | layer-filename helper(s) |
| `src/pasture_3d_layer_stack.{h,cpp}` | optional `get_manifest()` (metadata-only get_data) |
| `src/pasture_3d_layer.{h,cpp}` | optional per-region tile slice get/merge helpers |
| `src/unit_testing.{h,cpp}` | Phase 3 round-trip tests |
| `PASTURE3D_LAYERS_GUIDE.md` | mark phase 3 ✅ when done; note any new findings |

After Phase 3, the remaining phases are: 4 (editor routing + Layers panel), 5 (tool API +
RoadPastureConnector), 6 (sub-region tiling, drop `_tile_size` to 64), 7 (control/color layers).
Remember the aliasing fix (un-alias Base) is a **Phase 4 prerequisite** for live re-compositing.
