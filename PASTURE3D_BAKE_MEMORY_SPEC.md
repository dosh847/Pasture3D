# Pasture3D Bake Memory — Load/Unload Cycle of the Scoped Bake

**Document Version:** 1.0
**Target Engine:** Godot 4.7+ / GDExtension (C++ / GDScript)
**Status:** ACCEPTED 2026-09-26 (decisions in §11). Phases 1 and 2 committed (`bd459c91`, `3bbdcc53`);
phase 3 built, not yet committed.
**Evidence:** `project/bench/RegionBakeMemoryProbe.gd`, runs of 2026-09-26: a small world (6 × 6 regions of
256 m) and a large one (16 × 16 regions of 1024 m, 256 km²).
**Builds on:** `PASTURE3D_REGION_STREAMING_AND_TYPES_SPEC.md`, whose last item this is ("investigate memory
management for the bake's load/unload cycle, especially All regions"). Streaming phases 0–6 are in
commits up to `89c887a0`.

---

## 1. Scope

The scoped bake (`connectors/pasture3d_scoped_bake.gd`) was built to bound **correctness**: a region is
held until every owner that touches it has baked, then saved and unloaded. This spec is about the other
half, **peak memory**. The headline: streaming bounds the regions that are loaded, but several things the
bake keeps next to them grow with the size of the world. On the large fixture, an "All regions" bake peaks
at 5.65 GB of RAM, and 3 GB of GPU arrays stay allocated after it has released every region.

| ID | Finding | Status |
|----|---------|--------|
| M1 | Bake All's undo snapshots copy every baked tile, and none of it can be restored | **Built — Phase 1** |
| M2 | GPU slot capacity never shrinks | **Built — Phase 2** |
| M3 | Each unload rewrites the region index and layer manifest | **Built — Phase 3** |
| M4 | Owners bake in global layer order, so regions are held across the whole run | **Fix — Phase 4** |
| M5 | The default shared layer makes one owner the size of the world | **Fix — Phase 5** |
| M6 | Frozen modifier caches stay in memory for every baked brush | **Fix — Phase 6** |
| M7 | The only budget is a region count, with no back-pressure | **Fix — Phase 7** |
| — | Are released regions and their layer tiles freed? | **Yes.** Measured, see §2.3 |
| — | Per-brush stamp cache | **Not a finding.** Native routes never fill it, see §2.4 |

Order matters. M1 and M2 are the biggest and the simplest, and each one changes the numbers every later
phase is measured against. M7 (a budget) comes last because a budget is only useful once the peak it
guards is no larger than it has to be.

---

## 2. Measurements

### 2.1 The probe

`RegionBakeMemoryProbe.gd` builds a world of N × N blank regions in `user://region_bake_memory_probe`,
places brushes, bakes once with everything loaded (so every owner's layer exists on disk), unloads
everything, and then runs an "All regions" bake the way Bake All does: `load_for`, a `before` snapshot,
`bake_owner`, an `after` snapshot, `mark_baked`, `release_after`. Three fixtures:

- **F1:** one Mound per region, all on the default shared "Mounds" layer, so one owner.
- **F2:** one Mound straddling each right and each lower region boundary, each on its own layer, created in
  a seeded shuffled order. Layer order is creation order, so it is spatially arbitrary.
- **F3:** one Mound per region, each on its own layer, each with a Frozen erosion modifier.

It is a measurement, not a pass/fail gate, but its measures have witnesses:

- the peak-loaded simulator must reproduce the measured peak for the order the bake used;
- a region held by a variable must count as alive after unload (the weakref control);
- F3 must fill the erosion cache (the witness for the brush-cache measure);
- the undo snapshots must be non-empty.

Run: `--headless --path project res://bench/RegionBakeMemoryProbe.tscn -- --n=16 --size=1024 --fixtures=F1`.
Peak working set comes from the harness sampling the engine process (the `_console` exe is a wrapper).

### 2.2 Results

Small world, 6 × 6 × 256 m (the whole world's maps are 30 MB):

| | F1 | F2 | F3 |
|---|---|---|---|
| Owners | 1 | 60 | 36 |
| Peak regions loaded | 36 / 36 | 32 / 36 | 1 / 36 |
| Peak under a dependency-respecting greedy order | 36 | 20 | 1 |
| Undo snapshots, before + after | 9.0 MB | 15.0 MB | 9.0 MB |
| Share of snapshots in regions loaded for the bake | 100% | 100% | 100% |
| Frozen erosion caches after the bake | — | — | 2.1 MB |
| Slot capacity after the bake, 0 regions loaded | 48 | 48 | 48 |

Large world, 16 × 16 × 1024 m (the whole world's maps are 3.4 GB):

| | F1 | F2 | F3 |
|---|---|---|---|
| Owners (layers) | 1 (2) | 480 (481) | 256 (257) |
| Peak regions loaded | 256 / 256 | 220 / 256 | 1 / 256 |
| Peak under a dependency-respecting greedy order | 256 | 134 | 1 |
| Bake time (of which save + unload) | 105 s (21 s) | 163 s (78 s) | 128 s (41 s) |
| Undo snapshots, before + after | 1024 MB | 1080 MB | 1024 MB |
| Share in regions loaded for the bake | 100% | 100% | 100% |
| Frozen erosion caches after the bake | — | — | 222 MB |
| RAM during the bake: start → peak → after | 149 MB → 5.65 GB → 1.20 GB | 189 MB → 4.81 GB → 1.31 GB | 595 MB → 1.67 GB → 1.65 GB |
| RAM after dropping snapshots and caches | 159 MB | 200 MB | 160 MB |
| Peak working set of the whole run | 5.8 GB | 5.3 GB | 5.7 GB |
| Slot capacity after the bake, 0 loaded | 256 (3 GB of GPU arrays) | 256 | 256 |

RAM is Godot's allocator counter (`MEMORY_STATIC`), which holds the maps, tiles and snapshots. The
working-set row covers the whole run, **including the setup**, which loads every region for its first
bake; on F3 that setup, not the bake, is the peak. The bake's own peak is the "RAM during the bake" row.
F3 starts at 595 MB because the setup's own frozen solves are already cached.

Reading across:

- F1 and F2 are dominated by loaded regions (M4, M5); F3, whose owners each touch one region, is not, and
  yet still ends the bake at 1.65 GB with one region loaded: 1 GB of snapshots (M1), 222 MB of frozen
  caches (M6), and the rest the owners' layer bookkeeping.
- Every fixture ends with 1 GB or more of snapshots that undo cannot use (M1).
- Save + unload is 20–48% of the bake, and grows with the layer count (M3): F2's 481-layer manifest is
  rewritten on every one of its 256 unloads.

### 2.3 Released regions are freed

Every region object and every layer tile image the bake loaded was weakref'd at load. After the bake, none
is alive (0 of 16 896 on the large F1). The control (a region held by a variable) is seen as alive, then
freed once dropped. There are no `Ref` cycles holding released regions. RAM after the bake returns to its
starting level once the undo snapshots are dropped (159 MB against 149 MB).

### 2.4 The stamp cache is not a finding

`_stamp_cache` holds one full-resolution float grid per spline. It read zero entries on all three
fixtures, including F3, whose brushes carry a modifier stack. Both a plain Mound and one with modifiers
take the native `stamp_mound_loop` route, which never stores a stamp; only GDScript fallback routes do.
It is left alone.

---

## 3. M1 — Undo snapshots

### 3.1 Evidence

Bake All (`pasture3d_sim_manager.gd`, `_bake_all_owner`) takes `_snapshot_owner(owner)` before and after
each owner. A snapshot is a deep copy (`_copy_tiles`) of every tile of every layer the owner writes, for
every loaded region. The pair is kept:

1. in `p_ctx` for the whole run;
2. in the EditorUndoRedo action as the do/undo arguments;
3. in `last_bake_report["undo"]`.

On every fixture, 100% of the snapshot bytes belong to regions the bake loaded and later released. On the
large F1 that is 1 GB, and it is what keeps RAM at 1.2 GB after the bake instead of 159 MB.

### 3.2 It is also a correctness problem

A snapshot stores the region generations it was taken at, and `_restore_owner` skips any region whose
generation has changed (`restore_layer_tiles(idx, tiles, generations)`). Unloading bumps the generation.
So **undoing an All-regions bake restores nothing in any region the bake loaded**: the memory buys an undo
that silently does nothing for most of the world. Only regions that were already loaded, and so stay
loaded, are restored.

### 3.3 Decision (resolved: option (a))

Undo of a bake over regions that are no longer loaded. Options:

- **(a) No undo for released regions (recommended as the first step).** Don't snapshot a region the bake
  loads. Undo covers what was loaded before the bake and says so: the report lists the regions whose
  bake cannot be undone, and the manager says so before and after the bake.
- **(b) Disk-backed undo.** Before the bake first saves a region, copy its region file and layer slice into
  a per-action backup directory. Undo copies the files back and reloads any that are loaded. It costs disk
  and I/O, not RAM, and it makes undo real. It needs a policy for pruning backups when the undo history
  drops the action.

Recommendation: build (a) now, because it is the memory fix and it makes the current behaviour honest. Add
(b) as a later phase if undo over unloaded regions is wanted.

### 3.4 Fix, option (a) — built

- `_snapshot_owner(owner, p_exclude)` and `_copy_tiles(tiles, p_exclude)` leave excluded regions out
  entirely: no tiles, and no generation. A restore reads a region with no generation as "not in this
  snapshot" and skips it (`restore_layer_tiles`), so the filter needs no change on the restore side.
- Every Bake All snapshot (before, after, and the road-settle rebakes) excludes
  `_not_undoable(ctx)`: the scoped report's `loaded_for_bake` so far. The before snapshot is taken after
  `load_for`, so an owner's own loaded neighbours are already in it.
- The report gains `not_undoable` (the regions loaded for the bake).
- There is no dock for Bake All; the Sim Manager is its UI. So: the `bake_scope` tooltip says undo covers
  only regions that were loaded; the editor bake prints a notice before it starts when the scope is not
  All Loaded Regions; and the manager's configuration warnings name the count after a bake that had any.
- `debug_unfiltered_undo` restores the pre-M1 snapshots, for the controls.
- Also added: `bake_budget_regions` on the manager (default 64, passed to the scoped bake), so a probe can
  bake a world-sized owner through Bake All. It is a plain var; M7 replaces it.

### 3.5 Gate

- **[U1]** After an All-regions bake from an empty loaded set, the snapshots hold 0 bytes. Control: the
  unfiltered snapshot (a debug flag) holds more than 0.
- **[U2]** A region that was loaded before the bake is still restored by undo, byte for byte. Control: a
  region that was loaded for the bake is not, and is listed in `not_undoable`.
- **[U3]** RAM after the bake is within 10% of RAM before it (large fixture). Control: the unfiltered run
  exceeds it.

### 3.6 Results (2026-09-26)

`bench/RegionBakeUndoGate.tscn`: PASS, 3/3 criteria (U1, U2, and the warning with its control). The probe
now bakes through `bake_all_brushes_now` and measures U3 (`--unfiltered` is the control):

| Large F1 (16 × 16 × 1024 m) | Filtered (M1) | Unfiltered (control) |
|---|---|---|
| Undo snapshots | 0 MB | 1024 MB |
| RAM: start → peak → after | 151 MB → 5.13 GB → 160 MB (+6.0%) | 151 MB → 5.65 GB → 1.20 GB (+699%) |
| Peak working set | 5.3 GB | 5.8 GB |

Small world, all three fixtures: after the bake +0.1% to +0.4% filtered, +9% to +16% unfiltered. The peak
falls too, because the snapshots used to accumulate during the bake. Regression gates BrushRegistry,
RegionBakeScope, RegionUnload and TestBrushSinkFootprint pass.

---

## 4. M2 — Slot capacity never shrinks

### 4.1 Evidence

`_sync_slots` (`pasture_3d_data.cpp`) grows each pool in `SLOT_CHUNK` (16) steps and never shrinks it.
`_build_array` fills free slots with a full-size placeholder. After a bake that held the whole world, the
texture arrays keep that capacity with no regions loaded: 256 slots on the large fixture, 3 GB of height,
control and colour at 1024², before mipmaps. The runtime streamer shares the code, so a game that passes
through a dense area keeps its peak capacity for the rest of the session.

### 4.2 Fix — built

- At the end of `_sync_slots`, when `used * 2 + SLOT_CHUNK <= capacity` (less than half used, by half a
  chunk or more), the pool compacts: the used slots are packed down from 0 in slot order, the capacity
  becomes the next multiple of `SLOT_CHUNK` at or above the used count (0 when nothing is loaded), the
  pool's images are cleared so `_build_array` refills them, and the slots already handed out this call are
  renumbered. It returns "capacity changed", which recreates the arrays as growth already did.
- The region map is rebuilt from the slots right after `_sync_slots` in the same `update_maps`, so it
  follows the move with no change.
- The rule differs from the draft's "at most half, plus hysteresis" on one point: the half-chunk margin is
  the hysteresis. It keeps 16 of 32 used at 32 (`RegionSlotGate` RS3 asserts that a removal there does not
  recreate), and one region coming and going near a boundary never recreates anything. Under half, a bake
  releasing n regions recreates the arrays about log₂(n) times.
- `_sync_slots` runs once per `update_maps`, never inside a loop, so `ScopedBake.finish` needs no call of its
  own: its last release already compacts.

### 4.3 Gate

- **[S1]** Load 64 regions, unload 60: capacity drops to 16. Control: unloading 20 (44 left, more than half)
  leaves it at 64.
- **[S2]** After compaction, every loaded region still samples its own heights on the GPU path (the
  region map points at the moved slot). Control: compaction without the region map rebuild samples the wrong
  region.
- **[S3]** Streamer: moving a source away from a dense area drops capacity. Control: the pre-fix build keeps
  it.

### 4.4 Results (2026-09-26)

`bench/RegionSlotCompactGate.tscn`: PASS, 3/3 criteria. What the gate checks, and where it differs from §4.3:

- **S1:** 64 loaded, 60 unloaded one at a time with an update each: capacity 64 → 16, and 6 array
  creates (2 shrinks × 3 maps). Control: 20 unloaded (44 left) keeps 64 and creates nothing.
- **S2:** there is no GPU readback headless, so it checks what the shader reads. Each kept region's texel
  decodes to a slot whose uploaded height, control and colour images are that region's own maps. The four
  kept regions sat in the highest slots, so all four moved. Control: a neighbour's slot holds a different
  image. It then unloads a moved region and loads another: the slot table equals the loaded set.
- **Mutation:** dropping the `slots` renumbering from the compaction crashes the gate. S2's bookkeeping
  check was added because the first S2 could not see that.
- **S3:** a streamer in the middle of a 63-region block holds capacity 64, and moving within the block
  keeps it. Moving it to a lone region leaves 1 loaded at capacity 16.

Regression: all eleven other region gates pass (RegionSlot, RegionUnload, RegionType, RegionSeam,
RegionLayer, RegionStream, RegionWater, RegionLakeTile, RegionPanel, RegionBakeScope, RegionBakeUndo).

Large F1 (16 × 16 × 1024 m) through Bake All: capacity after the bake is **0, down from 256**, so the arrays
hold nothing with nothing loaded. The pre-M2 run left 256 slots, 3 GB of GPU arrays. The rest is unchanged
from phase 1: RAM 151 MB → 5.13 GB → 160 MB (+6.0%), bake 103 s, snapshots 0 MB. The probe's "capacity
before" also reads 0: the setup unloads everything after its pre-bake, and that now compacts too.

---

## 5. M3 — Each unload rewrites the index and manifest

### 5.1 Evidence

`unload_region` saves the region and then, every time, `_save_layer_manifest`, `_save_layer_slice`,
`_index_region` and `_save_region_index`. The index and the manifest describe the whole world, so an
All-regions bake over n regions writes them n times: O(n²) bytes, and the manifest also grows with the
layer count. Save + unload is 21 s of 105 s on the large F1 (2 layers) and 78 s of 163 s on F2 (481
layers).

### 5.2 Fix

- `unload_region` gains a batched form, or the data gains `begin_batch()` / `end_batch()`. Inside a batch,
  the manifest and index are marked dirty rather than written, and `end_batch()` writes them once.
- The scoped bake opens a batch in `begin` and closes it in `finish`, including on cancel.
- Crash safety: the region files are written as before. If the editor dies mid-bake, the index can be
  stale. The load path must tolerate that: a region file with no index entry is indexed on first scan,
  and an index entry whose file is newer is re-read. Check what `_index_region` needs and make the load path
  rebuild an entry from the file.

### 5.3 Gate

- **[I1]** An All-regions bake over n regions writes the index once. Count writes with a debug counter.
  Control: the unbatched path writes it n times.
- **[I2]** Kill the batch before `end_batch` (skip it in a debug mode): reloading the directory still finds
  every region and its correct type and ratio.
- **[I3]** Wall time of release on the large fixture drops. Report it; there is no threshold.

### 5.4 Fix as built — it differs from §5.2

- **The manifest is not batched: it is written only when it changed.** Its content is plain values (every
  layer's metadata and the stack version), so `_save_layer_manifest` hashes that, and skips the write when the
  hash, the path, and the file's modified time all match what this data last wrote. This is better than
  deferring it. The manifest on disk always knows every layer uid of every slice written after it, so a
  crash cannot leave a slice that points at layers the manifest lacks. An unchanged stack costs no write at
  all, not even one per bake. Every save path benefits, including `save_directory`.
- **The index is batched without a batch object.** `unload_region(loc, update, write_index = true)`: with
  false, the index is updated in memory only. The scoped bake's `_release` passes false, and `finish` calls
  the new `write_region_index()` once when anything was released. `finish` also runs on cancel. A
  `begin_batch`/`end_batch` pair was rejected because a batch left open, by a manager freed mid-bake, would
  have silently stopped every later unload from writing the index. The dock's Unload Selected does the same.
- **Crash safety needed no load-path change.** A crash after the releases leaves the index with its
  pre-bake entries. An unload never changes a region's type, ratio or lock, so those entries are still
  right. A stale height range is replaced when the region loads. A stale stack signature triggers a
  recomposite on load, from a manifest and slices that are consistent by the rule above, so the result equals
  the saved file (gate I2 checks exactly that).
- Write counters in `get_upload_stats()`: `index_writes`, `manifest_writes`, `manifest_skips`. The report
  gains `release_usec`. Controls: `ScopedBake.debug_index_per_unload`, also on the manager for the probe
  (`--index-per-unload`); and `debug_skip_index_write`, the crash.

### 5.5 Results (2026-09-26)

`bench/RegionIndexBatchGate.tscn`: PASS, 3/3 criteria.

- **I1:** a bake releasing 3 regions writes the index once. Control: per-unload writes it 3 times.
- **M:** the same bake writes the manifest 0 times, with 3 skips as the witness. Controls:
  - a renamed layer writes it, and the new name is on disk;
  - a deleted manifest file is written again.
- **I2:** the crash run's index on disk is stale, with a control showing the written run's index is not.
  - The stack changed while R1..R3 were unloaded, so the reload recomposites them from stale signatures.
  - Every region comes back with its type and ratio, in both the editor path and the index-only path.
  - Heights equal both the written run's and the saved files. The bake changed R1..R3, so the compare can
    fail.
- **Mutations:**
  - A manifest that is never rewritten once it exists fails M, and fails I2 on heights.
  - Removing `finish`'s index write fails I1.

Large F2 (16 × 16 × 1024 m, 481 layers): what the writes cost, now measured instead of assumed (the probe's
[W] line):

| | per write | × 256 releases |
|---|---|---|
| Region index | 1.3 ms | 0.3 s |
| Layer manifest (481 layers) | 21.2 ms | 5.4 s |
| Release total now (save + unload) | 83 ms per region | 21.3 s of a 101.5 s bake |

So M3 saved about 5.8 s of about 27 s of release on F2, almost all of it the manifest. The per-unload index
control times the same as the batched run (101.8 s against 101.6 s). **§5.1's premise was wrong:** release
time is mostly the region files themselves, not the index and manifest. The index batching still matters,
because its cost is O(n²). At 256 regions it is 0.3 s; at 4096 regions (a 64 × 64 world) each write would
be about 20 ms, so about 80 s. The 163 s → 101 s drop on F2 since the §2.2 baseline belongs mostly to
phase 1: the snapshots no longer copy 1 GB.

Also seen, not part of M3: F2's RAM after the bake is +13.9% (206 → 235 MB), against +6.0% on F1. The
3.8 MB brush caches do not explain it. Phase 8's re-measure should look at it.

Regression: all region gates, BrushRegistryGate and TestBrushSinkFootprintGate pass.

---

## 6. M4 — Bake order

### 6.1 Evidence

`plan()` sorts owners by layer order first, then by first region. A region touched by owners in several
layers stays loaded from the first of them to the last. On F2 the bake held 32 of 36 regions at once on the
small world, and 220 of 256 on the large one, while no owner touches more than 2.

### 6.2 Which constraint is real

Layer order is stricter than needed. Two owners must bake in layer order only when a later one reads the
earlier one's output where they overlap: a snap brush reads the layers below it, and a domain reader reads
the composite. Owners that share no area can bake in any order. The real constraint is a DAG: an edge from
each lower owner to every higher owner whose footprint boxes overlap it (the same `_boxes_overlap` the input
closure uses).

### 6.3 Fix

- Build the DAG in `plan()`.
- Schedule with a greedy list scheduler: among ready owners, prefer the one that loads the fewest new
  regions, then the one that releases the most. The probe's `_greedy_order` is this, keyed on shared regions
  rather than overlapping boxes. Boxes are the real constraint and are looser, so the real order can only
  do better.
- The refcount release rule is unchanged.

### 6.4 Limits

On F2 the greedy order still holds 20 of 36 (small) and 134 of 256 (large). Randomly ordered overlapping layers make long dependency
chains, and no order beats the chain. The fix narrows the peak; it does not bound it. M7 bounds it.

### 6.5 Gate

- **[O1]** The order respects every DAG edge (checked against a brute-force overlap scan). Control: the plain
  first-region sort violates at least one edge on F2.
- **[O2]** Every region's heights after the new order equal those after the layer-major order, byte for
  byte, on F2. Control: an order that violates one edge differs.
- **[O3]** Peak loaded on F2 is at most the greedy simulator's figure. Report both.

---

## 7. M5 — The shared default layer is one owner

### 7.1 Evidence

By default every Mound shares one "Mounds" layer, so they are one owner, and an owner is atomic: its bake
clears the layer and repaints every tool on it. On F1 the owner covers the whole world, so the bake loads
the whole world (256 of 256 regions, 5.65 GB). With the default `budget_regions` of 64, a real All-regions
bake would **skip** that owner on the large world instead (`skipped_budget`). The probe raises the budget to
measure it.

### 7.2 Decision needed

- **(a) Bake a shared owner in spatial chunks (recommended).** When an owner reads no domain,
  `_refresh_owner_rect` already clears a box and repaints only the tools that touch it. The scoped bake
  splits the owner into chunks (for example, connected groups of tools whose footprints overlap), and each
  chunk loads, bakes and releases like an owner. It keeps the one-layer workflow and bounds the peak by the
  largest connected group.
- **(b) One layer per brush by default.** Simple, but it changes what users see in the layer stack, and a
  world of thousands of brushes becomes thousands of layers.
- **(c) Leave it, and warn.** The dock warns when an owner exceeds the budget and names it.

Recommendation: (a), with (c)'s warning for an owner that reads the domain and so cannot be split.

### 7.3 Gate

- **[C1]** On F1 the chunked bake's heights equal the whole-owner bake's, byte for byte. Control: a chunk
  that clears its box but misses one overlapping tool differs.
- **[C2]** Peak loaded on F1 is the largest chunk's region count (4 at most for one Mound per region).
  Control: the unchunked bake loads 256.
- **[C3]** A domain-reading owner is not split and is named in the warning.

---

## 8. M6 — Frozen modifier caches

### 8.1 Evidence

Erosion, relief and graph modifiers default to or support Frozen: they keep their last solve in `_cache`,
in memory only (the erosion cache stores five float grids per bake grid). After Bake All clears and
re-solves every registered brush, each holds a fresh solve. That is independent of which regions are
loaded, so it grows with the number of brushes in the world. F3: 2.1 MB for 36 brushes on 118 m loops
(small world), 222 MB for 256 brushes on 471 m loops (large). A real mountain-sized erosion brush is larger
again.

### 8.2 Why it cannot just be dropped

Frozen is state, not a cache. A frozen modifier serves its stored solve on every rebake until the user
presses Bake; dropping the entry makes the next rebake re-solve on whatever the surface is then, which can
change the landscape. So "free the cache of a brush whose regions are all released" is not a memory fix, it
is a behaviour change.

### 8.3 Decision needed

- **(a) Spill to disk (recommended).** When a brush's regions are all released, write its frozen entries to
  a cache directory (`<data_directory>/.cache/`, or the project's `.godot` folder) keyed by the brush's
  scene path and the entry's extent, and drop them from memory. Reload on the next rebake that needs them.
  A missing file means "not frozen", which is the same as today after a reload.
- **(b) Keep them in memory with an LRU budget,** spilling the oldest. The same mechanism with a trigger.
- **(c) Leave it.** Document the cost.

### 8.4 Gate

- **[F1]** After spilling and reloading, a Frozen brush's bake is byte-identical to one that never spilled.
  Control: dropping without spilling re-solves and differs on a fixture where the surface changed.
- **[F2]** Memory held by caches after an All-regions bake on F3 is 0 once every region is released.
  Control: the pre-fix build holds it.

---

## 9. M7 — A memory budget with back-pressure

### 9.1 Evidence

`budget_regions` (default 64) skips an owner that touches more regions than that; it never limits how many
regions are loaded at once across owners. After M4 and M5, peak memory is the peak working set of loaded
regions plus whatever the owner being baked allocates.

### 9.2 Fix

- A byte budget, `bake_memory_budget_mb`, in the scoped bake, measured from the loaded regions' map and
  layer tile sizes (known from the region type and layer count; no allocator probing).
- Before `load_for`, if loading the owner's missing regions would exceed the budget, the scheduler picks a
  different ready owner that fits. If none fits, it releases regions whose remaining owners are furthest in
  the plan, **saving them first**. A region released early is reloaded when a later owner needs it, so the
  bake's result must be unchanged; the refcount rule becomes "release when unneeded, or when the budget
  requires it".
- An owner larger than the budget on its own still bakes, alone, and is reported (it cannot be split
  further without M5's chunking).

### 9.3 Gate

- **[B1]** With a budget of k regions on F2, peak loaded never exceeds k, except while baking an owner
  larger than k. Control: no budget exceeds k.
- **[B2]** Heights are byte-identical with and without the budget. Control: releasing a region without
  saving it first loses its edits and differs.
- **[B3]** Reported: wall time with the budget against without (reloads cost I/O).

---

## 10. Phases

| Phase | Finding | Done when |
|-------|---------|-----------|
| 0 | Probe committed as the measuring harness; large-world baseline recorded in §2.2 | Baseline recorded 2026-09-26; probe committed in `bd459c91` |
| 1 | M1 undo snapshots, option (a) | Built 2026-09-26: U1–U3 pass; large F1 RAM after the bake +6.0% |
| 2 | M2 slot compaction | Built 2026-09-26: S1–S3 pass; large F1 capacity after the bake 0 (was 256) |
| 3 | M3 batched index and manifest | Built 2026-09-26: I1, M, I2 pass; F2 release 21.3 s, writes saved ~5.8 s |
| 4 | M4 dependency-ordered schedule | O1–O3 pass |
| 5 | M5 chunked shared owner, option (a) | C1–C3 pass |
| 6 | M6 frozen cache spill, option (a) | F1–F2 pass |
| 7 | M7 byte budget with back-pressure | B1–B3 pass |
| 8 | Re-measure the large world | Probe re-run on all fixtures; §2.2 gains an "after" column |

Each phase's gate follows the bench-gate practices: every criterion has a control that fails, and the gate
counts completed criteria, not only failures. Large-world runs take several minutes and several GB of
RAM; they are perf tests, so ask before running them.

---

## 11. Resolved questions (2026-09-26)

1. M1: option (a). A region the bake had to load is not undoable, and the report and the dock say so.
   Disk-backed undo (b) is not planned.
2. M5: option (a). A shared owner that reads no domain is baked in spatial chunks; one that reads the
   domain is not split, and the dock warns when it is over the budget.
3. M6: option (a), spill to disk. The spill goes under the project's `.godot` folder
   (`res://.godot/pasture3d_frozen/`), not beside the terrain data. A frozen entry has never survived a
   reload, so a per-machine, unversioned location keeps that behaviour and keeps tens of MB of float grids
   out of version control.
4. M7: a fixed default figure, chosen in phase 7 from the phase 8 measurements, and settable per bake.
