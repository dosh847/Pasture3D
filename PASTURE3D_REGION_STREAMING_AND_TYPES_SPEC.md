# Pasture3D Region Streaming and Region Types

**Status (2026-09-25): phase 0 built and gated (`bench/RegionUnloadGate`, commit c2388feb); phase 1
built and gated (`bench/RegionSlotGate` 8/8, `bench/RegionSlotRenderProbe` windowed, commit 2015f72c);
phase 2 split into 2a and 2b, both built and gated (`bench/RegionTypeGate` 8/8, `bench/RegionLayerGate`
9/9, commit decc3889); phase 3 built and gated (`bench/RegionSeamGate` 5/5, `bench/RegionSeamRenderProbe`
windowed 4/4, commit 3cc36c2e); phase 4 built and gated (`bench/RegionBakeScopeGate` 10/10, commit 1422e15a; see "Phase 4 as built"); phase 4b built and gated (`bench/RegionWaterGate` 6/6, `bench/RegionLakeTileGate` 5/5, `bench/RegionWaterRenderProbe` windowed 4/4, commit d9f03e9d; see "Phase 4b as built"); phase 5 built and gated (`bench/RegionPanelGate` 6/6; see "Phase 5 as built"); phase 6 built and gated (`bench/RegionStreamGate` 7/7, commit 6420d975; see "Phase 6 as built"). All phases are built; the memory investigation below is next.** Check the symbols named here before trusting this
header: specs in this repo go stale.

Phase 6 as built (game streaming and multi-source collision, §H; deviations marked):

- **Streamer.** `src/pasture_3d_streamer.h/.cpp`, a C++ `Node` (not a subresource), `Pasture3DStreamer`.
  Properties: `enabled`, `terrain`, `sources`, `threaded`, `max_pending_loads`, `max_adopts_per_frame`,
  `adopt_budget_msec`, `feed_collision`. With no sources set it uses the terrain's `get_cameras()`, then the
  viewport camera; sources that were set but left the tree do NOT fall back to the camera. It runs only in a
  game (`tick()` is public so a gate can drive it). *Deviation:* the queue is ordered by distance ÷ (1 +
  priority), not distance ÷ priority, so priority 0 is valid. Distance is to the region's rectangle, not its
  centre.
- **Load split.** `Pasture3DData::load_region` is now a disk read plus `adopt_region(loc, region, path,
  legacy, slice, update)`, the main-thread half (one slot upload, one map texel, the layer slice merge). The
  streamer reads through `ResourceLoader.load_threaded_request` and adopts at most `max_adopts_per_frame` per
  frame, stopping early once `adopt_budget_msec` is spent (the first adopt of a frame always runs). A read
  whose sources left before it finished is dropped on arrival; a failed read is not retried.
- **Release, not unload.** *Deviation:* the streamer calls a new `release_region`, which drops a region
  without saving and returns `ERR_BUSY` for a modified or deleted one. A game never writes region data: a
  region with changes not on disk stays loaded and is reported once through the new `region_kept` signal.
  (`unload_region` still auto-saves, for the editor.)
- **Starting from the index.** *New:* `Pasture3D.region_loading` (Regions group; replaced the earlier
  `load_all_regions` bool on 2026-09-27). Auto (default): a game loads only the region index when an enabled
  Pasture3DStreamer drives the terrain, found by walking the scene hierarchy while it enters (a streamer later
  in the scene has not entered yet but exists), and every region when none does. All and Streamed force
  either. The index now stores `region_size`, since no loaded region can supply it; an index written before
  that reads one region file for the size. Every region file on disk without an index entry gets a bare entry.
- **The editor reopens with its last loaded set** (2026-09-27). Each index entry records `loaded`: a load
  indexes it true, a drop sets it false, unload writes the index after the drop, and the dock's Load writes it
  too. The editor skips a file whose entry says false; an entry without the key reads as loaded. A game ignores
  the record (`Pasture3D.restores_region_state`). Gate: bench/RegionLoadStateGate.
- **Collision.** `Pasture3D.collision_targets` (new, an array of `Node3D`) gives DYNAMIC collision one patch per
  target. The streamer's `feed_collision` passes its sources in. The shape pool is grid_width² × target count;
  disabled shapes are parked far away. *Deviation:* a region-map change no longer rebuilds the pool.
  `on_region_map_changed` diffs a per-region signature (object, texel ratio, whether its type collides), and
  only the shapes over regions that differ are rebuilt; FULL mode still rebuilds. `_grab_camera` keeps physics
  processing on while a collision target exists (it used to turn it off headless, which froze the patches).
- **Signals:** `region_loaded`, `region_unloaded`, `region_kept`, `streaming_idle`. `get_stats()` returns
  counters (requests, threaded requests, adopted, released, dropped, failed, kept, pending, the largest
  per-frame adopt count and time) for gates and profiling.
- **Not built:** streaming in the editor (the editor loads everything, as §H scoped it); a memory budget
  (see the investigation after the phase table).
- **Gate** `bench/RegionStreamGate` 7/7: ST1 index-only start loads what the source is near, with threaded
  reads; ST2 a streamed region is byte-identical to its file; ST3 two sources about 1.9 km apart both have ground
  (control: feed_collision off leaves one without); ST4 moving inside the hysteresis band loads and unloads
  nothing (control: unload radius = load radius thrashes, 11 events); ST5 adopts stay within the per-frame
  count and a 0 ms budget still adopts one; ST6 a region loaded or released under a still patch changes its
  collision without replacing the body (witness: the body RID; control: `build()` replaces it); ST7 nothing
  is written, and a modified region is kept (control: `unload_region` writes).

Phase 5 as built (region gizmo and panel, §G; deviations marked):

- **Selection model.** `src/region_selection.gd` (RefCounted, preloaded, no class_name) owns the selection
  and every action; the dock and the viewport only call it, and the gate measures it. `known()` is loaded
  regions plus index entries, **minus regions deleted this session**. The index still names those until
  the next save, and a naive union would draw and select a region that is gone.
- **Modifiers. Changed:** Ctrl already inverts Add/Subtract in the Region tool, so selection uses Shift:
  click replaces, Shift-click toggles, drag box-replaces, Shift-drag box-adds, Shift+Ctrl-drag box-removes.
  A plain click selects wherever add/remove would do nothing: Add over any known region, Subtract over an
  unloaded one or empty ground (`RegionSelection.gesture`). Add on empty ground and Subtract on a loaded
  region still stroke as before.
- **Only Load loads. Changed:** Lock, Set Type and Delete act on loaded regions and report the unloaded ones
  as skipped ("not loaded"), rather than loading them to act. Only Load and Bake Selected bring regions in.
  Every action returns `{done, skipped{loc: reason}}`, and the dock prints the reasons.
- **Delete** runs the editor's own Region Subtract stroke at each region's centre, so it is one undo action
  and goes through the same lock refusal; the tool and operation are restored after. Locked regions are
  skipped.
- **Set Type** asks with a ConfirmationDialog when `downsampled_by(type)` is non-empty (a loaded, unlocked
  region whose texel ratio would increase), naming the count and the ratio.
- **Bake Selected. Changed:** the dock calls `Pasture3DScopedBake.bake(SELECTED, selection)` synchronously:
  no progress and no Cancel. The registry's `bake_regions` is still typed by hand; the dock does not
  write it.
- **Inspector:** location, state, type and ratio, resolution, lock, unsaved changes, memory. Memory is the
  bytes the maps hold (height and control RF, colour RGBA8 with mipmaps); for an unloaded region it is the
  same sum at the index's ratio, marked "~".
- **Gizmo.** `src/region_gizmo.gd`: `lines()` is pure, and `show()` puts a PRIMITIVE_LINES mesh on an
  INTERNAL child of the terrain, so it is never saved into the scene. Outlines sit 1 m above the top of the
  height range, drawn without depth test. Loaded regions are solid, unloaded dashed (alpha ×0.75), locked
  hatched, selected with a white inner outline, and the drag box is yellow.
- **New guard (C++).** Region Add or `auto_regions` sculpting over an indexed location that is not loaded
  used to create a blank region there, and its save would overwrite the file on disk. `_operate_region` now
  refuses it: "not loaded; load it from the Regions dock first".
- **Fix:** `box()` built its array with a ternary, which yields an untyped Array; a typed `Array[Vector2i]`
  refuses that at runtime. Only a box that was not a replace could hit it.
- **Deferred:** editor streaming (keeping regions near the camera loaded) is not built; it belongs with
  phase 6's streamer.
- Gate `bench/RegionPanelGate` (headless, user:// data), 6/6:
  - RP1 known/state/info. Control: the index still names the deleted E.
  - RP2 click/toggle/box and the gesture and modifier tables. Control: the box's 12 locations hold 4
    regions.
  - RP3 actions, with the skip reasons. D's unsaved edit is written by Unload. Controls: a second unload is
    skipped; adding D changes Bake Selected's targets.
  - RP4 `downsampled_by` names only the loaded Standard region. Control: Standard names none.
  - RP5 gizmo segment counts and tints per state, plus the box, with each outline inside its region.
  - RP6 the Add guard. Control: an unindexed location still gets a region; once loaded, D keeps its edit.
- Not gated: the dock's widgets and the viewport input routing (`_forward_region_selection`) need the
  editor. Check them by hand.

Phase 4b as built (water terrain check and tiled shore SDF, §I; deviations marked):

- **Region map "unloaded" value.** `Pasture3DData::REGION_MAP_UNLOADED = -(1 << 21)`. `_rebuild_region_map`
  writes it for every index location that is empty in the map and not in `_regions`. A location still in
  `_regions` is loaded, or deleted and not yet saved, which is no region; it is never "unknown".
  `region_map_decode` returns -1 for it, so every CPU reader treats it as no region. **Changed 2026-09-26:**
  the GPU texel is NOT -(1 << 21) but `REGION_MAP_UNLOADED_TEXEL` = 0.25. It is not an integer, so
  `int(round(v))` in `region_map_slot` (and `int(v + 0.5) - 1` in the extras shaders) already reads it as
  no region. The explicit `v == -2097152` test it replaced ran per fragment tap and cost the terrain 4%.
  Only the water check reads the raw float (`raw > 0.125` on its `e == 0` branch). `_load_region_index` marks the map dirty. RegionSlotGate's map-consistency check now accepts
  the value only at an indexed, unloaded location (its RS5 expected 0 before).
- **Globals come from the terrain material.** `Pasture3DMaterial::register_terrain_globals()` declares
  `pasture3d_region_map`, `pasture3d_height_maps`, `pasture3d_coarse_height_maps` and `pasture3d_terrain`
  (vertex_spacing, region_size, region_map_size, coarse_store_shift). The same four are in project.godot
  and the editor plugin's list. `_update_uniforms` publishes them. `uninitialize` clears them if this
  terrain was the publisher (`s_globals_terrain`). A zero region size makes the check inert, so a scene
  with no terrain shows all its water. The terrain names no water type. Also registered from
  `Pasture3DPoolManager::register_water_globals`.
- **The check** is `extras/shaders/water/water_terrain.gdshaderinc`, included by `water_surface.gdshaderinc`
  under `WATER_TERRAIN_CHECK`. That define requires `WATER_CLIPMAP` (an `#error` otherwise), and it is
  defined by `water_ocean`, `water_ocean_low` and `water_lake_clipmap`. States: 0 no region, 1 unloaded,
  2 land (stored height ≥ level + `land_margin`, holes included), 3 water. A coarse region is read at its
  lattice texel `(local >> shift) << (shift - coarse_store_shift)`. The CPU mirror is
  `Pasture3DData::get_water_terrain_state` / `is_water_hidden`.
- **Deviation: a vertex is removed only when five taps all hide it.** The taps are its centre plus the
  corners at ±`scale · WATER_TERRAIN_REACH` (3.5 cells, the shore mask's reach). The spec's single test
  was wrong: a NaN vertex takes every triangle using it, so a lone vertex over land also cut the water
  beside it. The cost is five fetch pairs per vertex, not one. **Measured 2026-09-26** (`bench/RegionWaterCheckBench`,
  windowed, 1280×800): ocean over the demo terrain, the level splitting it into land and water, the shipped
  shader against a runtime copy without `WATER_TERRAIN_CHECK`, 4 alternating rounds. High and low tiers at
  pitch −20° and −50°: ON−OFF between −0.7% and +0.7% of a ~0.67–0.74 ms frame, every one inside the spread
  between repeats of the same arm. The cost is below what this machine can resolve. Witness: with
  `land_margin` −1000 the ON image loses the ocean over the terrain (mean delta 0.086) and OFF does not
  change (0.000). Trap: `Pasture3DOcean.set_material` ignores the material it already holds, so a uniform
  edited on that same object never reaches the ocean's private duplicate; the first witness read 0.000 for
  both arms because of it.
- **Tiled shore SDF** (`pasture3d_pool.gd`, `mask_tiles` Auto / Always / Never). It applies to clipmapped
  bodies only; Auto tiles a field wider than `TILE_AUTO_TEXELS` (4096). Tiles sit on the source brush's
  terrain region grid, or on `TILE_FALLBACK` (256 m) with no terrain. A tile is n = ceil(tile / mask_texel)
  texels plus a 1-texel apron, sampled at uv = ((g − ti)·n + 1)/(n + 2).
  `Pasture3DUtil.classify_shore_tiles` marks a tile as a band tile if a shore segment piece, grown by
  `mask_range + 2s`, touches it. Every other tile is a constant, inside or outside. Only band tiles
  are baked, and only where the region is not indexed-unloaded. The tile map (RF) holds 0 for outside or
  not baked, −1 for inside, and k+1 for layer k. `region_map_changed` rebakes or drops tiles. Moving the
  body re-plans the grid.
- **Found by the gate: a tile must be baked with a margin of the range.** The baker seeds exact distance
  only where the shore crosses its image. A shore passing just outside a bare tile was never seen, so the
  tile read up to 21 m wrong. Tiles are now baked `ceil(range / s) + 3` texels wider on each side and
  cropped. The single image never hit this, because it is already padded by the range.
- **Containment mask capped.** A masked body's mask is coarsened by doublings past `MASK_CAP` (4096²
  cells), because it is O(area): 557 M cells for a 30 km lake at wave spacing. Boundary cells still fall
  through to the exact test. `mask_spacing` is in the build stats.
- **Known limit, not fixed:** containment's exact test is `Geometry2D.is_point_in_polygon`, which is
  float32. On a 30 km lake it misplaces points about 0.1 m from the shore. The field itself is right to
  1 cm (LT2).
- Gates:
  - **RW** (`bench/RegionWaterGate`, headless, 6/6): the CPU mirror. RW1 encoding (control: the index
    entry removed gives 0), RW2 unknown vs nothing, RW3 cave (control: margin 30), RW4 seabed pit
    (control: level −30), RW5 reach (control: radius 0), RW6 coarse lattice (control: an unshifted read
    disagrees).
  - **RegionWaterRenderProbe** (windowed, 4/4): P1 the shader agrees with the mirror at feature points
    and stripe edges (control: the check compiled out); P2 no shoreline gap on 20 m cells (control:
    reach 0 leaves gaps); P3 the globals are cleared when the terrain leaves the tree; P4 the three
    shipped shaders show the sea and remove land and unloaded regions.
  - **LT** (`bench/RegionLakeTileGate`, headless, 5/5, a 30 km lake):
    - LT1 bakes tiled: 596 band tiles of 13924, 34 MB against 766 MB (control: one image needs 20044
      texels).
    - LT2 the emulated shader read is within 0.011 m of exact near the shore, tile edges included
      (control: without the apron, 0.95 m).
    - LT3 a tile over an unloaded region waits for it, loads through the signal and drops on unload
      (control: an unindexed location is baked).
    - LT4 constant tiles are out of range (control: margin 0 leaves 72 in range).
    - LT5 the mask is capped, and containment agrees with the fallback (control: the mask alone
      disagrees).

Phase 4 as built (bake scope, §F; deviations marked):

- `connectors/pasture3d_scoped_bake.gd` (a RefCounted; no `class_name`, preload it: a new global class
  needs an editor rescan). `plan(scope, targets)` is a dry run; `bake(scope, targets)` returns the §F
  report plus `ok`, `owners` and an ordered `events` log of `["load"|"bake"|"release", …]`.
- **Deviation: the unit of work is the layer OWNER, not the brush.** `_refresh_owner` clears and repaints
  every tool bound to a layer, so one brush of a shared layer cannot be baked alone; baking a subset would
  repaint its layer-mates over a clipped domain. An owner's working set is the union of its tools'
  `_own_footprints()`, and locks and the budget skip whole owners.
- **"Reads below" means reads its DOMAIN:** an enabled erosion modifier, a growing relief material, or an
  active graph modifier (frozen ones too, because Bake All clears freezes). A pointwise sample of the
  ground is served by the lower layers' tiles as last baked, which the load brings in. The closure adds
  every lower-layer owner whose footprint boxes overlap a domain reader's, recursively.
- Each owner bakes the way Bake All's step does (full resolution, stamp caches dropped, layer-brush owners
  through `bake_layer`), but synchronously. A whole-owner bake takes no dirty-rect path, so the phase 2
  clip-edge renormalisation cannot make scopes differ.
- The budget is a region count (`budget_regions`, default 64), not bytes.
- Live rule: `Pasture3DTerrainBrush.reaches_unloaded_region()` (a footprint region is indexed but not
  loaded). `_can_auto_refresh` refuses on it and the brush shows a "needs bake" configuration warning.
- **Fixed in passing: re-saving an unchanged layer slice or manifest wrote different bytes.** The binary
  saver draws a random `local://` id for any resource without one, including the main resource, and every
  unload re-saves the region's slice. Slices and the manifest now carry fixed ids (`stack`, `layer_<i>`).
  Found by RB3: a region outside the working set changed on disk with identical content.
- Gate RB (headless, user:// data) fixture: S (R1 only, lowest layer), A (R0|R1, craggy + LIVE erosion),
  B (R1|R2), R3 untouched. RB1 scopes agree byte-for-byte (control: a clipped bake differs, inside R1
  too); RB2 release after the last sharer (control: `debug_release_early`); RB3 changed files lie in the
  working set (control: working-set files did change); RB4 loaded set restored (control: the bake loaded
  regions); RB5 closure (control: erosion off drops S); RB6 live rule; RB7 locked (loaded and via the
  index) and budget skips, each with an unlocked or unlimited control.
- Fixture trap: the default Mound is an uncapped slope-angle cone; its peak is 60 m × tan 30° and it never
  reads `height`. Edit `slope_angle` to make a bake do work.

- **Brush registry.** `Pasture3DSimManager` has `bake_scope` (Selected / All Loaded / All Regions,
  default All Loaded) and `bake_regions` (Selected's targets, typed by hand until the phase 5 gizmo). Bake
  All Brushes plans through the scoped bake with `root_owners` = the registered owners: a registered brush
  is baked when it touches a target, the closure adds what it reads, and only registered brushes have
  their caches cleared. It drives the steps (`begin` / `load_for` / `mark_baked` / `release_after` /
  `settle_roads` / `finish`), so the deferred per-owner solve and Cancel are unchanged. **Changed:** owners
  now run in layer order, not the registry list's first-appearance order, because the closure needs its
  inputs first. The report gains `scope`, `loaded_for_bake`, `released`, `regions_written`,
  `skipped_locked`, `skipped_budget`, `road_turns`, `roads_unsettled` and `events`.
- **Undo across a scoped bake** covers the regions that stay loaded. A region loaded for the bake is saved
  and released, and its generation guard makes undo skip it (the phase 0 rule: a dirty unload drops undo).
- **Roads: the junction fixed point runs inside the bake.** After the first pass, `settle_roads` resolves
  each network with a baked road (live refreshes suppressed), re-bakes the owners whose pins moved beyond
  tolerance, and repeats, at most `ROAD_SETTLE_TURNS` (4). Regions a road owner touches carry an extra
  reference released only after the settle. A road outside the baked owners whose pins moved is reported
  in `roads_unsettled`, not loaded.
- **Graphs.** A Road, Shape or Spline Source names an input by REFERENCE: the named brush's owner joins
  the closure regardless of overlap, searched from the host's terrain ancestor as
  `Pasture3DGraphSources` does. Sources are **not** skipped when the named brush reaches an unloaded
  region (a deviation from §F's first sentence): they read scene geometry and a road's solved alignment,
  not region data, and skipping them would make a bake's result depend on the loaded set. What §F's rule
  is for, not operating on unloaded data, is held by the live rule, and by the graph editor, whose
  previews mark themselves stale for a host that reaches an unloaded region.
- `Dictionary.merge` does not overwrite by default. `begin` merging `ok: true` into a context that already
  held `ok: false` made every bake a silent no-op. The gate's earlier criteria passed only because they
  ran before that change.
- Gate additions: RB8 a crossing on a hill straddling R0 | R1 settles in 3 resolves, R1 is released only
  after the last one, and a fresh resolve then moves no pins (control: `debug_no_road_settle`, where a
  fresh resolve moves both roads; a weak control, since without the settle nothing resolved at all). RB9
  Bake All Brushes over Selected [R0] bakes A and its closure S, not the unregistered B, restores the
  loaded set, and matches the scoped bake's R0 (control: R2 still holds the snapshot). RB10 a Shape Source
  pulls in the brush it names across the map (control: an empty key). A graph needs an Output node to be
  active, and an inactive graph names nothing.

Still open:

- Clear Simulation On All Brushes is not scoped: it re-bakes registered owners over the loaded regions.
- Budget is a region count, not bytes; peak memory is the post-phase investigation below.
- The deferred resolve a road bake queues still runs after the scoped bake. It finds the network settled
  and changes nothing, but it is a redundant resolve.

Phase 3 as built (Background rendering, §D; deviations marked):

- **Two array sets, not one per ratio (deviation).** `POOL_FINE` holds Standard regions at full size, and
  `POOL_COARSE` holds every coarse region at the finest coarse ratio loaded (`get_coarse_store_ratio`). A
  coarser region in the same pool is uploaded upsampled to that ratio, and the shader reads only its lattice
  texels for height, so mixed coarse ratios work but cost the finest one's VRAM. A change in the store
  ratio recreates the coarse arrays. Each pool has its own slots, free list and placeholders
  (`get_coarse_slot_locations`, `get_coarse_maps`, `get_coarse_maps_rid`).
- **Region map encoding:** still an RF texture of exact integers. A Standard region is `(slot+1) |
  color_only<<20`, a coarse one `-((slot+1) | shift<<16 | collapse<<19 | color_only<<20)`. The shader and C++
  id is `abs(v)-1`: `slot | flags`, or -1 for none. The encoding is defined only in `region_map_encode` and
  `region_map.glsl`, and the macros `REGION_SLOT/LAYER/SHIFT/COLLAPSE/COLOR_ONLY/COARSE` read it.
  `region_id_slot` and `region_id_is_coarse` are the C++ readers.
- **Shaders:**
  - `vertex_height(pos)` is the GPU twin of `get_height_at_vertex`: bilinear on a coarse lattice, with the
    far corners taken from the neighbour's vertex (the edge texel when there is none).
  - `fetch_control`/`fetch_color` read the texel at or before the position, and colour sampling shifts the
    mip by the store ratio.
  - The shaders no longer read `_region_locations`: the region's own position is passed in.
  - COLOR_ONLY regions skip `accumulate_material` and use a neutral material under the colour map.
- **Vertex collapse:** a vertex over a collapsing region snaps to the lattice point **at or before** it,
  never the nearest one. Nearest would put the last row on the finer neighbour's edge and leave that edge's
  own vertices standing off it. The last cell fans into the neighbour's fine edge vertices.
- **Collapse and culling:** a collapsed vertex moves up to `ratio-1` vertices toward -x/-z, which can carry
  a triangle out of its clipmap mesh's cull AABB. The mesher widens each mesh AABB on those sides by
  `get_default_xz_back_margin()`. That is a new `Pasture3DClipmapHost` virtual, 0 by default; the terrain
  answers `(get_collapse_ratio_max()-1) * subdiv`. It is refreshed on `region_map_changed`. Without it, a
  narrow camera (the picking camera, 0.1 m ortho) missed 4 of 16 samples down a collapsed cell.
- **Seam stitch, on the data (as §D).** `_stitch_region` runs inside `update_maps` for every edited or fresh
  region and its four neighbours (all regions on a full update). Where a region's -x or -z neighbour is
  coarser, its first column/row between that neighbour's lattice points becomes the straight line, so the
  fan is planar. The neighbour's ratio comes from the loaded region, else the region index. The last
  segment ends on the next region's origin: it is skipped while that region is unloaded but indexed, and
  held flat at the world's edge. A restitched region uploads height only and is marked modified, so the
  stitch is saved. `set_seam_stitch_enabled(false)` (not saved) exists only as a gate control.
- **Normals:** the fragment scales its derivative offsets and the normal's y by the region's ratio
  (`region_ratio_at`), so a coarse region is lit at its own spacing.
- **Proofs:**
  - RegionSeamGate: the stitch oracle on both axes; the toggle; unloaded neighbours (restitch from the
    index; the last segment held); layer bytes of exactly 16:1 (a ratio-2 control gives 4:1); the
    encoding.
  - RegionSeamRenderProbe: GPU picking against CPU `get_height` over the last cell is 0.019 m stitched
    and 2.4 m unstitched. A cell centre is 2.0 off the bilinear with collapse and 0.019 without. There
    is no clear colour along the border (control: the world edge).
  - VRAM: `RENDER_TEXTURE_MEM_USED` gives exactly 16:1 per layer once a fixed 2,732 B per-layer counter
    residual, the same in both pools, is taken off. Raw, it is 15.29:1.
- **Limitations:**
  - The extras shaders (lightweight, minimum, particles) treat a coarse region as absent.
  - The displacement buffer has no per-ratio normals.
  - A stitch flattens the Standard edge's detail irreversibly.
  - A restitch caused by an edit to a corner origin leaves the neighbour's collision slightly stale until
    its next collision update.
  - The `max_regions` warning is demoted to DEBUG, because slots no longer index `_region_locations`.
  - **Open: terrain frame time.** `WaterBodiesPhase2Gate` [A] measured `terrain_clipmap` at 0.316 ms against
    its 0.278 ms reference (+13.7%, pixels identical). The phase 3 vertex shader adds a region-map lookup per
    vertex for collapse, but the reference may also be stale. **Decided 2026-09-26 by A/B** (the same gate
    run from a worktree build of each commit, two runs each, ocean_high_pitch20 as the unchanged control at
    0.266–0.271 ms throughout): decc3889 (phase 2) 0.282/0.283, 3cc36c2e (phase 3) 0.311/0.313, 1422e15a
    (phase 4) 0.311/0.311, d9f03e9d (phase 4b) 0.325/0.324, HEAD 6420d975 0.327/0.329 ms. The reference is
    NOT stale (phase 2 matches it within 1.5%). The rise is real and has two parts: phase 3 +0.029 ms
    (+10%, the collapse and coarse reads), and phase 4b +0.013 ms (+4%) from ONE compare,
    `v == -2097152` in `region_map_slot`: d9f03e9d with only that line reverted times 0.311/0.312.
    `region_map_slot` runs per fragment tap, so the unloaded test is paid on every pixel. **Resolved
    2026-09-26:** the unloaded GPU texel is now 0.25 (see "Phase 4b as built"), and HEAD times 0.314/0.314
    ms. The user accepted phase 3's +10%: `WaterBodiesPhase2Gate` compares `terrain_clipmap` against an
    accepted 0.314 ms (`ACCEPTED_MS`), still printing the 0.278 reference. The pre-fix 0.328 would fail
    that band (+4.5% against ±3%).
  - `RegionSlotRenderProbe` now waits for physics ticks: the clipmap snaps in `_physics_process`, and a
    fixed 6-frame wait was racing it (flaky, not a regression).

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
