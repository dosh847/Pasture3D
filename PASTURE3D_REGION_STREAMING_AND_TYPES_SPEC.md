# Pasture3D Region Streaming and Region Types

**Status (2026-09-25): phase 0 built and gated (`bench/RegionUnloadGate`, commit c2388feb); phase 1
built and gated (`bench/RegionSlotGate` 8/8, `bench/RegionSlotRenderProbe` windowed, commit 2015f72c);
phase 2 split into 2a and 2b, both built and gated (`bench/RegionTypeGate` 8/8, `bench/RegionLayerGate`
9/9, uncommitted on `feat/region-streaming-phase0`); phases 3–6 not started.** Check the symbols named here before
trusting this header: specs in this repo go stale.

Phase 2a as built (types, CPU data paths, toggles, lock):

- `Pasture3DRegionType` (C++ `Resource`). The built-ins ship as `addons/pasture_3d/region_types/standard.tres`
  and `background.tres` (ratio 4, collision off, instances DROP, colour-only material, load 8 km, unload 9 km).
- A region stores its type by path (`type_path`), plus a cached `texel_ratio` and `locked`. An empty or
  missing path means Standard. A type must be a saved resource (res:// or user://): `set_region_type`
  refuses an unsaved one with `ERR_FILE_BAD_PATH`. It's a mismatch (`is_region_type_mismatched`) when the
  cached ratio differs from the type's. The region index entry records the path, ratio and lock.
- `region_size` is still the world footprint; the map is `region_size / texel_ratio`. Coarse texel i sits
  on fine vertex i·r. `world_to_pixel` returns the texel at or before the position.
- **Heights:** `get_height` bilerps fine vertices through `get_height_at_vertex`. On a coarse region a
  vertex is bilinear on the lattice, and a lattice corner past the far edge is the neighbour's vertex (the
  edge texel if there's no neighbour). The last fine cell meets the neighbour's own vertices, so the
  surface has no crack at the seam. Fixed in passing: within 0.01 of a vertex, `get_height` snapped to the
  vertex at or before the position, not the nearest one.
- **Resampling on a type change:**
  - Coarsening: height is a width-r box centred on the lattice vertex, with half weight at the ends,
    clamped to the region. Control is the lattice texel. Colour is the cell mean.
  - Refining: height is point-sampled from the current surface. Control and colour use floor lookup.
  - `import_images` refuses coarse regions. `change_region_size` refuses while any region is coarse.
- **GPU (temporary shim until phase 3):** a coarse region uploads a full-size copy, upsampled exactly as
  the CPU samples it, into its normal slot.
- **Collision:** a region whose type has collision off contributes holes. A coarse region with collision
  on is read through `get_height_at_vertex`.
- **Instances:** a DROP type clears the region's instances on conversion, and `append_region` refuses new
  ones.
- **Lock and toggles in the editor:**
  - A locked region refuses hand strokes, instancer strokes, Region-tool delete and `set_region_type`
    (`ERR_LOCKED`).
  - `sculptable` and `paintable` are checked per region per stroke.
  - Refusals are reported once per region per stroke, via `Pasture3DEditor.get_stroke_refusals()` and the
    plugin's `flash_region_warning`.
- **Coarse strokes** write only at lattice vertices, so each texel gets the brush once (not r²).

Phase 2b as built (the layer stack on coarse regions, §E):

- Over a coarse region, layer pixels are the region's MAP pixels, and a tile's edge is
  `min(tile_size, map size)` (`Pasture3DLayer.get_region_tile_size`). The stack owns a region → map size
  Dictionary that every layer shares. Pasture3DData keeps it current from `_adopt_region_into_bases`
  (every region joining the stack), `set_region_type`, `load_layers` and `set_layer_stack`. A layer joins
  the stack before it gets tiles, so a Base or typed Base is built at the right size.
- **Batched writes** (`_apply_stamp_block`: brushes, graph sinks, `stamp_grid`) evaluate at full
  resolution. Each texel takes the region-coarsening box over the cells the block wrote, with NaN cells
  left out and the weights renormalised. A texel is written only when its own lattice vertex is non-NaN,
  so the footprint and a dirty-rect clip are decided as on a Standard region. **Control blocks** take the
  word at the lattice vertex.
- **Point writers:**
  - Height (`set_height_on_layer`, `add_height_on_layer`, `_stamp_write`) writes only at lattice
    vertices, so a writer walking fine vertices reaches each texel once.
  - Control and colour points take the texel under the point.
  - Hand strokes through a layer are lattice-gated, like direct strokes.
- **Clearing** (`clear_layer_in_area`) on a coarse region zeroes coverage for exactly the texels in the box
  (`clear_samples_in_rect`), not whole tiles. A coarse tile covers more ground than the caller's
  tile-aligned dirty box, so dropping it would lose other brushes' writes.
- **Below-sampling** (`composite_height_below`, `get_height_below_point`) is bilinear on the lattice, with
  the far edge held.
- **Conversion resamples every layer's tiles** for the region, then recomposites. Nothing is discarded.
  - Height: coverage-premultiplied bilinear on the old lattice, then the region box when coarsening.
  - Control: the word at the lattice vertex.
  - Colour: an alpha-weighted cell mean when coarsening, floor lookup when refining.
  - A single-layer Base that aliases the region map is re-aliased instead.
- Fixed in passing: `layered_to_image` blitted a coarse region's small map into a full-size rect. It now
  exports what the GPU samples.

Phase 2 limitations (later phases):

- **A dirty-rect bake is not texel-identical to a full bake near the clip edge.** The clip blanks cells
  outside the box, so an edge texel's box renormalises over fewer taps. Phase 4's byte-identical criteria
  must account for this: pass the block unclipped to the filter and clip only the texel decision.
- Below-sampling holds a coarse region's far edge instead of reading the neighbour's layers, so the last
  lattice cell differs slightly from `get_height`.
- Refining an overlay interpolates its coverage bilinearly, which feathers its hard edges by one old texel.
- A sculpt stroke into an ADD user layer authors the absolute height, counting the ground twice. The Layers
  dock creates REPLACE layers, so only the scripting API reaches it. This predates phase 2.
- The GPU shim's far edge follows the neighbours at upload time. It isn't refreshed when only a neighbour
  changes (phase 3 replaces the shim).
- The Average tool is weaker on a coarse region: it averages texels, not vertices.
- The lock covers hand strokes and type changes, not the scripting API (`set_pixel`, the `*_on_layer`
  writers, `import_images` on a Standard region).
- Converting a region has no undo yet; the phase 5 Set Type dialog confirms it.
- `material_mode`, `vertex_collapse`, `priority` and the load/unload radii are stored but unused until
  phases 3 and 6.

Phase 1 as built (deviations from §B marked):

- Slots: `_slot_locations` / `_region_slots`, lowest free slot first, capacity grows by 16 and only growth
  recreates the arrays. `get_region_id` now returns the SLOT, not the index in `region_locations`, and
  `set_region_locations` (reorder, undo) never moves a slot. A region object replaced at the same location
  is re-uploaded (slots remember the uploaded ObjectID).
- **Deviation: the map is `RF`, not `R32I`.** Godot's `Image` has no integer format. Texels are exact small
  integers, 0 = none, else slot + 1. The encoding is defined in `Pasture3DData::region_map_encode/decode` and
  `shaders/region_map.glsl` (`region_map_slot()`), nowhere else. There is no type-array index yet; that
  arrives with phase 2.
- **Deviation: the whole map is re-uploaded** on a change (`texture_2d_update`; 256² floats), not only the
  changed texels. `get_upload_stats()` counts it as one `region_map_uploads`.
- `pasture_3d/regions/region_map_size` (default 256, power of two in [32, 1024], restart required).
  `Pasture3DData.get_region_map_size()` replaces the removed `REGION_MAP_SIZE` constant: a breaking change
  for GDScript users of the constant. The extras shaders and the particle example moved to the texture.
- Adding or removing a region still rebuilds every MMI (`update_mmis(-1, V2I_MAX, true)`), unchanged from
  before; left for phase 6 streaming.
- ui.gd's NONE-background region-tool preview wrote negative values into the map and was already inert
  (the shader's slot bound rejected them). It was removed.

Phase 0 as built:

- `Pasture3DData.unload_region` / `is_region_loaded` / `load_region` (now returns `Error`), with the signals
  `region_loaded` and `region_unloaded`.
- `Pasture3DRegionIndex` in `pasture3d_region_index.res`. An entry describes the region's FILE, so a
  modified region's entry is not rewritten until it is saved.
- Layers have a stable `layer_uid`, and slices match their layers by uid. Legacy slices with no uid fall
  back to index matching.
- If the stack signature changed while a region was unloaded, loading it recomposites the region.
- Per-location generations. The C++ editor undo, bake undo and layer Clear skip regions that were unloaded
  or reloaded since the snapshot, via `restore_layer_tiles`.
- `Pasture3DInstancer.destroy_by_location`.
- Fixed in passing:
  - Composites never marked their region modified.
  - `remove_region` left the region's layer slice on disk.
  - A freshly loaded region came in flagged modified.
- Not gated headless: the C++ editor `_apply_undo` guard, which needs the editor plugin.

## Goal

Make regions the unit of large-world scale:

1. Regions load and unload individually, in the editor and in game.
2. Each region has a **region type**. It is a resource like `Pasture3DRoadType`. The built-in types are
   `Standard` (today's behaviour) and `Background` (lower-res maps, wider vertex spacing). Users make
   their own types by duplicating and editing one.
3. A **region gizmo** selects regions so they can be loaded, unloaded, locked or retyped.
4. In-game **distance streaming** from **multiple sources** (split-screen players, AI actors), which also
   drives collision.
5. The world is larger than the fixed 32×32 region map.

## Decisions (agreed 2026-09-25)

| Question | Decision |
|---|---|
| Background footprint | **Same world footprint** as Standard, with fewer texels and a wider effective vertex spacing. The region grid, file naming and neighbour logic stay uniform. |
| Where Background saves | **Separate low-res texture arrays**, chosen in the shader by region type. Saves VRAM, RAM and disk. Costs a shader branch and a seam stitch. |
| Unloaded regions | **Nothing operates on an unloaded region.** Brushes, graphs, previews and roads work only on loaded regions. Only a **bake** loads a region: it loads, bakes, saves and unloads. |
| Bake scope | **Selected regions** (loads any selected region that isn't loaded), **All loaded regions**, or **All regions**. |
| Bake neighbours | A bake loads every neighbour that shares a brush with a target region, and a region isn't unloaded until every brush it shares with a neighbour has baked (section F). |
| Map size | `region_map_size` is a **project setting**. |
| Seam stitch | **Written into the Standard region's data**, not a shader skirt. |
| Ocean / water over unloaded regions | Treated as **unknown**: when a region is hidden, its water is hidden too. See section I for the terrain check. |
| Background foliage | A per-type option: **drop** instances, or **keep and scatter its own**. Some backgrounds are close enough to benefit, or use the scatter for large props like city buildings. |
| Standard → Background | **Downsample and discard, with a confirm dialog.** Undo covers the session. Background → Standard upsamples. |
| Streaming and collision | **Every streaming source gets a collision patch** in DYNAMIC modes. |
| World size | **Sparse, texture-backed region map** (e.g. 256×256 locations). Texture-array slots are allocated only for loaded regions. |
| Unloading a dirty region (editor) | **Auto-save, then unload.** The region's undo history is dropped. |
| Extras in scope | Distance streaming (multi-source), a larger map, per-type feature toggles, and region lock. |

## What the code does today (the constraints)

- `region_size` and `vertex_spacing` are **terrain-global** (`Pasture3D::_region_size`,
  `Pasture3DData::_vertex_spacing`). `load_region`/`load_directory` reject a size mismatch
  (`pasture_3d_data.cpp` ~L934, ~L987).
- Height/control/colour maps live in three `Texture2DArray`s (`_generated_*_maps`). Every slice must be
  the same size.
- The region map is `uniform int _region_map[1024]` (32×32, `REGION_MAP_SIZE`) in `main.glsl`. It limits
  the world to about 8 km at 256 × 1 m.
- **A region's slot is its index in `_region_locations`.** `remove_region` does `remove_at`, which
  shifts every later slot, so every add or remove rebuilds all the arrays. That's fine for editing and
  far too slow for streaming.
- **There is no unload.** `remove_region` means *delete on save*.
- `load_directory` loads every `pasture3d_*.res` up front, and nothing keeps an on-disk index of which
  regions exist.
- The clipmap already supports several cameras (`set_cameras`, one clipmap per camera), but collision
  follows only one target.
- Layer stack tiles are keyed by region location (`Pasture3DLayer::_tiles[region_loc]`), and a new
  region gets base layers through `_adopt_region_into_bases`. Unloading has to evict those tiles too.

## Architecture

### A. Three region states

| State | Meaning |
|---|---|
| **On disk** | The file exists. It is in the region index but not in memory. |
| **Loaded** | A `Pasture3DRegion` is in memory and holds an array slot. It is rendered and editable (unless locked). |
| **Deleted** | Today's `remove_region`: loaded, marked `_deleted`, and removed from disk on save. |

`Pasture3DData` gains a **region index**: every location that exists on disk, with its type and height
range. It lives in a small manifest (`pasture3d_regions.res`) that is rewritten on save and rebuilt by a
directory scan if it is missing. The gizmo, the streamer and bake auto-load all read the index, not
`_regions`.

New API: `unload_region(loc)`, `load_region(loc)` (reworked), `is_region_loaded(loc)`,
`get_region_index()`, and `region_loaded(loc)`/`region_unloaded(loc)` signals. `remove_region` keeps its
delete meaning.

### B. Stable slots and a sparse map

- **Slots are decoupled from `_region_locations` order.** Each region type has a slot pool: a free list
  over a pre-sized `Texture2DArray` whose capacity grows in chunks. Loading takes a free slot and uploads
  **one layer**. Unloading returns the slot. Nothing else is re-uploaded.
- **The region map becomes an `R32I` texture** (size from the project setting
  `pasture_3d/regions/region_map_size`, default 256). Each texel encodes the slot plus the type-array index, or 0 for no region. Only changed
  texels are updated.
- Every shader function that reads `_region_map[]` (`main.glsl`, `displacement_buffer.glsl`,
  `editor_functions.glsl`, `debug_views.glsl`, `backgrounds.glsl`) and every C++ reader
  (`get_region_map_index`, the water clipmap, the ocean, the instancer) moves to the new encoding in one
  commit. *(Memory: component gates miss wiring. A value defined in several places is fixed in none, so
  define the encoding once.)*

### C. Region types

`Pasture3DRegionType` is a **C++ `Resource`**. The texture arrays and the shader need it natively, so
it can't be a GDScript resource like the road type.

| Group | Setting | Standard | Background |
|---|---|---|---|
| Identity | `type_name`, `editor_color` (gizmo tint) | "Standard" | "Background" |
| Resolution | `texel_ratio` (divisor of `region_size`: 1, 2, 4, 8, 16) | 1 | 4 |
| Resolution | `vertex_collapse` (the mesh treats the region as coarse spacing) | off | on |
| Features | `collision` | on | off |
| Features | `instancer_mode`: KEEP / DROP (DROP clears the region's instances when a region converts to this type, after a confirm) | KEEP | DROP |
| Features | `material_mode`: FULL / COLOR_ONLY (skip the splat blend) | FULL | COLOR_ONLY |
| Features | `sculptable`, `paintable` | on | on |
| Streaming | `load_radius`, `unload_radius` (hysteresis), `priority` | e.g. 1.5 km / 1.8 km | e.g. 8 km / 9 km |

- A region stores its **type path** and a **cached `texel_ratio`**, so the file describes itself even if
  the type resource moves. When the stored ratio doesn't match the type's, the region is flagged and
  converted only on an explicit user action, never silently.
- The built-in types ship as `.tres` files in the addon. "New Region Type" duplicates the selected type
  into the project.
- Changing a type's `texel_ratio` affects every region of that type, so the inspector confirms it and
  lists how many regions (and how many unloaded ones) it will resample.
- **Region lock** is a per-region flag, not a type setting. Locked regions refuse hand strokes, and
  bakes skip them and report it (same model as [[brush-layers-are-not-hand-paintable]]: refuse, don't
  silently drop).

### D. Background rendering

- There is one array set per distinct `texel_ratio` in use (in practice 1 and 4). The shader looks up
  the type-array index from the region map texel and samples the matching array with
  `uv * (1/texel_ratio)`.
- **Seam stitch:** at a Standard↔Background border, the Standard side's edge row is constrained to the
  bilinear interpolation of the Background edge. This is enforced **on the Standard region's data when
  it is written** (the bake/compose writes the stitched edge), not in the shader. That way collision,
  CPU height queries and the GPU all agree by construction ([[jfa-not-exact-distance-transform]]
  principle). The stitch is re-applied whenever either neighbour changes resolution or is rebaked. When
  the Background neighbour is unloaded, the Standard edge keeps its last stitched values: unloading a
  neighbour must not move an edge.
- **Vertex collapse:** in the clipmap vertex shader, a vertex over a region whose `texel_ratio > 1`
  snaps to that region's coarse lattice, so the mesh doesn't spend fine triangles on coarse data. Any
  real triangle-count saving comes later: this saves shading detail, not draw cost. If profiling (ask
  first, [[ask-before-perf-tests]]) says it isn't enough, a separate backdrop mesh can come later.
- Normals are computed at the region's own texel spacing, not `_vertex_spacing`.

### E. CPU data paths

Anything that reads heights by region-local pixel has to respect `texel_ratio`: `get_height`,
`get_pixel`, raycast fallback, collision shape building, the instancer, `do_for_regions`, the layer
compositor, the brush raster, graph grid sampling, and road grading. The rule: **world→pixel
conversion goes through one function per region** (`region->world_to_pixel`) and nothing computes it
inline. Phase 2 greps every inline `/ _vertex_spacing` and `% _region_size` and routes it through that
function.

Layers: a layer tile over a Background region is stored at that region's resolution. Brushes and
graphs still **evaluate at full resolution** and are downsampled on write (box filter). A later
Background→Standard conversion then loses detail only on hand-painted data.

### F. Unloaded regions and bake scope

**Rule: nothing operates on an unloaded region.** Live brush updates, graph evaluation and previews,
road grading, hand strokes and the instancer all see only loaded regions. A graph operates only over
brushes that are in loaded regions.

A bake is the only operation that may load a region, and it leaves the loaded set exactly as it
found it.

#### Bake scope

The scope picks the **target regions**. The neighbour rule below turns targets into the regions that
are actually loaded and written.

| Scope | Target regions |
|---|---|
| **Selected regions** | The gizmo's selection, **loaded or not** |
| **All loaded regions** | Every loaded region |
| **All regions** | Every region in the index |

#### Neighbour rule

**A brush bake is atomic over its footprint.** A brush is never baked over only part of its footprint,
because a solver (erosion, stream-log, DLA) sees its whole domain, and a clipped domain bakes a
different result that seams at the cut.

1. **Brushes to bake** = every brush whose footprint (including `modifier_margin`) touches a target
   region, minus brushes touching a locked region.
2. **Input closure:** if a brush reads the composite below it, the brushes feeding that input are
   added too, recursively. A brush that doesn't read below adds nothing. This is what keeps a road
   network from pulling in the whole world when every brush over it is a pointwise stamp.
3. **Working set** = the union of the footprints of all brushes to bake. Every region in it is
   **loaded** (if it isn't already) and **written**. A neighbour loaded only to complete a brush is
   written only by that brush's layer; its other brushes are untouched.
4. **Release:** each region loaded for the bake holds a reference count, one per pending brush that
   touches it. A region is saved and unloaded only when its count reaches zero, meaning **every
   brush it shares with a neighbour has baked**. Regions that were loaded before the bake are never
   unloaded.
5. **Order:** brushes bake in layer order (input closure first). Within that, the scheduler groups
   brushes by shared regions so a loaded neighbour is reused before it's released.
6. **Budget:** if the working set of a single brush (plus its input closure) exceeds the bake memory
   budget, that brush is skipped and reported, not baked in pieces.

Locked regions are never written. A brush touching a locked region is skipped in every scope and
reported, because baking it atomically would write the locked region.

The bake result reports
`{scope, targets, regions_written, loaded_for_bake, released, skipped_locked, skipped_budget}`, so a
gate can assert what happened and not just the heights
([[a-gate-that-calls-the-node-measures-nothing]]). Because brush bakes are atomic, a result no longer
depends on the scope: **all three scopes bake a given brush identically.** Staleness stays a bake-time
fact per brush ([[brush-registry-bake-all]]).

#### Live editing (not a bake)

Live updates and graph previews don't load anything. A brush whose footprint reaches an unloaded
region **doesn't run live**. It shows as "needs bake" in the registry and the gizmo, and it's baked
by any scope that targets one of its regions.

### G. Editor gizmo and panel

- **Region gizmo:** in Region mode, every region in the index is drawn as a flat outline at its height
  range, tinted by type colour. Loaded regions are solid, unloaded ones dashed, locked ones hatched.
  Click selects, Shift/Ctrl adds or removes, and drag box-selects.
- **Actions on the selection:** Load, Unload (auto-save first), Bake Selected, Lock/Unlock, Set Type…
  (downsampling asks for confirmation), Delete (today's remove).
- **Inspector:** a selected region shows its location, type, lock state, resolution, dirty flag and
  memory cost.
- **Editor streaming (optional toggle):** keep regions within N of the editor camera loaded, and never
  auto-unload a dirty or selected region.

### H. Game streaming

- `Pasture3DStreamer` is a node or a `Pasture3D` subresource. It holds **streaming sources**
  (`Node3D`s), and defaults to `get_cameras()` when none are set.
- Each tick it takes, for each region in the index, the minimum distance to any source. It loads when
  that distance is under the type's `load_radius` and unloads when it is over `unload_radius`. The
  queue is ordered by distance ÷ priority.
- **Threaded loading:** a region is loaded with `ResourceLoader.load_threaded_request` (or a worker from
  the pool manager) and its data is prepared off-thread. Only the slot upload and the region-map texel
  write happen on the main thread, with a per-frame budget.
- **Collision:** `Pasture3DCollision` DYNAMIC modes build one patch per streaming source (reusing the
  shape pool), and skip region types with `collision = false`. FULL modes cover loaded regions only.
- **Signals:** `region_loaded`, `region_unloaded`, and `streaming_idle` (for loading screens).

### I. Water and terrain presence (investigated 2026-09-25)

**Today no water checks the terrain at all.**

- **Ocean** (`Pasture3DOcean`): an unbounded camera-centred clipmap plane at `sea_level`. Land hides
  it only through the depth test.
- **Lakes** (`pasture3d_pool.gd`): cut to a **2D shore SDF baked from the lake polygon**
  (`Pasture3DUtil.build_shore_sdf`). No terrain is sampled.
- Depth fade and shore foam read the scene depth buffer.
- Terrain holes discard their vertices by writing NaN (`main.glsl` ~L228). The water beneath a hole
  is still drawn.

What goes wrong without a terrain check:

1. **Unloaded regions look like open sea.** The ocean carries on across an unloaded island, because
   nothing tells it land is there.
2. **Dry spaces below sea level flood.** Wherever terrain is hidden (a cave through a hole, an
   underground room), the ocean plane at sea level shows through. It's only hidden where terrain
   geometry happens to cover it.
3. **Large lakes don't scale.** The shore SDF is one image over the lake's whole bounds:
   `texels = extent / mask_texel`. At the default `mask_texel` of 1.5 m, a lake wider than about
   24.5 km exceeds the 16384-texel GPU texture limit. Memory grows with the square of the extent, and
   the whole image is rebuilt on every edit. A 65 km world makes this reachable.
4. **Overdraw.** The ocean shades under every continent and relies on the depth test to reject it.

**Recommendation: yes, keep a terrain check.** It should be a region-map check plus a height check,
not the existing shore SDF, and it runs in the **water vertex shader**, collapsing vertices with the
same NaN trick the terrain uses for holes:

| Region map says | Water |
|---|---|
| No region at this location (outside the world) | **Shown**: open sea beyond the terrain |
| Region exists but **unloaded** | **Hidden**: unknown |
| Region loaded, terrain height ≥ water level + `land_margin` | **Hidden**: certainly under land (fixes caves and overdraw) |
| Region loaded, terrain height < water level + `land_margin` | **Shown**; the depth buffer draws the exact shoreline as now |

- The height is the **stored height, even under a hole**. A hole in dry land hides the water; a hole
  in the seabed keeps it (a flooded pit).
- `land_margin` (a few metres) keeps the cut conservative. The vertex-level test is only as fine as
  the water clipmap's spacing, so it removes only water that is certainly under land, and the
  depth-buffer shoreline stays in charge of the visible edge.
- To tell "no region" from "unloaded", **the region map texture must encode "exists, unloaded"**, as
  a separate value from 0. That makes the region index part of the map (section B).
- The region map texture and the height arrays are exposed to water materials as **global shader
  uniforms**, so any water shader can include the check without the terrain knowing about it.

**Large lakes:** the shore SDF becomes **tiled per region**, baked only for loaded regions and
dropped on unload, so memory follows what's loaded, not the lake's size. With the terrain check
above, the SDF only has to shape the lake's own shoreline; land occlusion is no longer its job.

**Cost:** two texel fetches per water vertex (the map, then the height). Measure it before and after
([[ask-before-perf-tests]]).

## Phases

| # | Phase | Proves |
|---|---|---|
| 0 | **Region index and unload.** Manifest, `unload_region`, separate unload from delete, and evict layer tiles and instancer MMIs. | Unload then reload round-trips byte-identical; a dirty unload auto-saves; `remove_region` still deletes. |
| 1 | **Stable slots and sparse map texture.** Slot pool and free list, `R32I` map, all shaders and C++ readers moved to it. | Loading or unloading one region uploads exactly one layer (count uploads); a region at location (±100, ±100) renders; the old 32×32 fixture is unchanged. |
| 2 | **Region type resource and per-region `texel_ratio` in data paths.** C++ `Pasture3DRegionType`, built-ins, `world_to_pixel`, feature toggles, lock. | Height queries on a ratio-4 region match the downsampled oracle; toggles actually remove collision and instances; locked regions refuse strokes. |
| 3 | **Background rendering.** Per-ratio arrays, shader branch, seam stitch, vertex collapse, per-ratio normals. | No seam crack at a Standard/Background border (sample both sides); VRAM for a ratio-4 region is 1/16. |
| 4 | **Bake scope and the neighbour rule.** Registry, graph, roads; Selected / All loaded / All regions; atomic brushes, input closure, ref-counted release. | One brush over two regions bakes byte-identically under all three scopes (control: a deliberately clipped bake differs). A region is not released while a brush it shares is pending (control: releasing early fails this criterion). Regions outside the working set stay byte-identical on disk. The loaded set after the bake equals the loaded set before it. |
| 4b | **Water terrain check and tiled shore SDF.** | The ocean is hidden over an unloaded region and shown beyond the world edge (control: an unencoded "unloaded" value shows water); a below-sea-level cave floor under dry land shows no water; a seabed hole keeps water; a lake over 25 km bakes. |
| 5 | **Region gizmo and panel.** | Selection, bulk actions, and the Set Type confirm dialog. |
| 6 | **Streaming and multi-source collision.** Streamer, threaded load, per-source collision. | Two sources far apart both keep ground collision; hysteresis doesn't thrash; the main-thread upload stays within budget. |

**After all phases are complete: investigate memory management for the bake's load/unload cycle,
especially "All regions".** The ref-counted release in F bounds correctness, not peak memory. Things
to look at: the scheduling order that minimises the peak working set (a spatial sweep versus layer
order), a hard memory budget with back-pressure, whether a released region's layer tiles and caches
are actually freed (Godot `Ref` cycles, frozen modifier caches), and measuring peak RSS on a large
world ([[ask-before-perf-tests]]).

Each phase's gates follow [[bench-gate-practices]]. Every criterion gets a control that fails, and the
gate counts completions, not just failures ([[gate-pass-can-mean-nothing-ran]]).

## Resolved questions (2026-09-25)

1. Map size: the project setting `pasture_3d/regions/region_map_size`, default 256. Changing it
   re-encodes the map texture; region files are unaffected.
2. Seam stitch: written into the Standard region's data (see D).
3. Ocean and water: an unloaded region is **unknown**, so its water is hidden. After investigating,
   the terrain check stays too, as a height test against the stored height (section I).
4. Background foliage: the type's `instancer_mode` (KEEP / DROP) decides it (see C).
5. Graph preview over unloaded regions: nothing operates on them. Previews show only loaded regions,
   and a graph operates only over brushes in loaded regions (see F).
