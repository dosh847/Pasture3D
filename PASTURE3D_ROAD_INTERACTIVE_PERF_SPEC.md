# Pasture3D Road — Interactive Editor Freeze Remediation & Real-Time Performance Specification

**Document:** `PASTURE3D_ROAD_INTERACTIVE_PERF_SPEC.md`  
**Status:** **PROPOSED / SPECIFICATION**  
**Phase:** **P11** (Interactive Spline Point Drag & Synchronous Invalidation Remediation)  
**Target:** `Pasture3DRoadBrush`, `Pasture3DRoadChunkHost`, `Pasture3DRoadNetwork`, `Pasture3DRoadJunctionSolver`, `Pasture3DTerrainBrush`  
**References:**  
- `PASTURE3D_ROAD_BRUSH_PERF_SPEC.md` (Native road rasterization & dirty rect section caching)
- `PASTURE3D_ROAD_PERF_REGRESSION_SPEC.md` (R1..R12 regression remediation & gate standards)
- `PASTURE3D_ROAD_STALENESS_AND_COST_SPEC.md` (S1..S12 cost reduction & digest caching)
- `PASTURE3D_ROAD_JUNCTION_PAINT_AND_SMOOTHING_SPEC.md` (P9a-0/P9a junction polygons & markings)
- `PASTURE3D_ROAD_END_CONNECTION_SPEC.md` (P10 endpoint connection topology)

---

## 1. Executive Summary & Problem Statement

### 1.1 The Symptom
When an author edits a road in the Godot 3D editor (e.g. moving a single spline control point in `demo_road_network.tscn`):
1. **Interactive Spline Drag is Smooth**: While the mouse is held down, the spline handles follow the mouse smoothly (~0.03 ms per frame) because `_on_refresh_timer` correctly defers full bakes during active drag.
2. **Synchronous Mouse-Release Freeze (800 ms – 1000 ms)**: The instant the mouse button is released, the Godot editor locks up completely for approximately 1 second while synchronous recalculation occurs.
3. **Cascading Multi-Frame Follow-Up Freezes (> 2.5 seconds total)**: Across subsequent frames, crossing roads detect digest changes caused by minor elevation and trim shifts at junctions. They schedule follow-up junction rebakes on consecutive frames, triggering a series of secondary freezes that lock the editor for another 1.5 – 2.0 seconds.

### 1.2 Empirical Profiling Trace on `demo_road_network.tscn`
Empirical profiling of a single spline point move on `Road3` at the 4-way intersection in `demo_road_network.tscn` (4 roads, 7 junctions, terrain size $512 \times 512$, grid $432 \times 432 = 186,624$ cells) revealed the exact microsecond cost distribution:

| Operation / Stage | Measured Latency | % of Frame | Primary Mechanism |
|---|---|---|---|
| **Layer Tool Repaint (`_refresh_owner_rect`)** | **735.58 ms** | **72.6%** | Overlapping tile clear forces all 3 intersecting roads (`Road1`, `Road`, `Road2`) to repaint in interpreted GDScript. |
| ↳ `Road1._paint_into` | 251.81 ms | 24.8% | Full-corridor GDScript evaluation, earthwork merge, footprint battering. |
| ↳ `Road._paint_into` | 242.82 ms | 23.9% | Full-corridor GDScript evaluation, earthwork merge, footprint battering. |
| ↳ `Road2._paint_into` | 153.22 ms | 15.1% | Full-corridor GDScript evaluation, earthwork merge, footprint battering. |
| ↳ `_merge_junction_earthwork` (per road) | 141.56 ms | 14.0% | Re-grades crossing partner roads across the entire $187\text{k}$ cell terrain grid. |
| ↳ `grade_junction_footprints` (per road) | 160.15 ms | 15.8% | Scans all $187\text{k}$ cells 7 times in GDScript for vertical rise; evaluates thousands of polygon tests. |
| **Junction Network Resolve (`net.resolve_junctions`)** | **277.97 ms** | **27.4%** | Re-solves all 7 junctions, trims, lane graphs, and surface geometry. |
| ↳ `build_junction_surfaces` / `rebuild_aprons` | **202.07 ms** | **19.9%** | Destroys all 7 apron meshes and collision shapes; reconstructs them from scratch unconditionally. |
| ↳ Topological crossing & lane solver | 75.90 ms | 7.5% | Re-computes lane connectors, stop lines, give-way markings, and arm geometry. |
| **Cascading Partner Rebakes** | **> 1,500 ms** | **Secondary** | `b.junction_digest() != b.last_junction_digest` fires on `Road`, `Road1`, and `Road2`, queuing cascading full-bake frames. |
| **Total Synchronous & Cascading Latency** | **> 2,500 ms** | **100%** | Multi-second editor unresponsiveness on a single point move. |

---

## 2. Root Cause Analysis (The 5 Architectural Bottlenecks)

### Bottleneck 1: Uncached Apron Surface Rebuilding (`rebuild_aprons`)
**Location:** [`project/addons/pasture_3d/roads/pasture3d_road_chunk_host.gd:378-422`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_chunk_host.gd#L378-L422)

Unlike road ribbon chunks—which compare `_last_digest` against previous inputs and exit in 0.5 ms when unchanged—`Pasture3DRoadChunkHost.rebuild_aprons` unconditionally calls `_clear()` on entry. For every junction in the entire scene:
1. It deletes and frees every existing `MeshInstance3D`, marking mesh, and collider.
2. It generates planar triangle fans via `Pasture3DRoadMesher.build_footprint`.
3. It constructs new `ArrayMesh` resources and allocates new `MeshInstance3D` nodes.
4. It calls `_add_junction_markings` (allocating additional meshes for stop bars, connectors, and give-way lines).
5. It runs `Pasture3DRoadMesher.build_footprint` a *second time* at zero lift to generate `ConcavePolygonShape3D` colliders.
6. It attaches new `StaticBody3D` nodes to the scene tree.

When 7 junctions exist in the project, this destroys and rebuilds 14 meshes, 7 colliders, and dozens of markings nodes on every single point drag release, taking **202.07 ms**, even if 6 of the 7 junctions were hundreds of meters away and completely untouched.

---

### Bottleneck 2: Full-Grid Rise Scan & Unbounded Evaluation in `_batter_junction_footprint`
**Location:** [`project/addons/pasture_3d/roads/pasture3d_road_brush.gd:1425-1485`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_brush.gd#L1425-L1485)

In `_batter_junction_footprint`:
```gdscript
var rise := 0.0
for idx in p_ground.size():
    var h: float = p_ground[idx]
    if is_finite(h):
        rise = maxf(rise, maxf(h - z_lo, z_hi - h))
var reach: float = rise / minf(cut_batter, fill_batter) + verge
```
1. **Global Array Scan in GDScript**: `p_ground` contains $186,624$ floats. For each junction, this loop executes $186,624$ GDScript iterations. Across 7 junctions, that is **$1.3$ million iterations** simply to calculate `rise`.
2. **Distant Mountain Contamination**: If the terrain has a mountain peak 500 meters away with elevation $200\text{ m}$, `rise` evaluates to $180\text{ m}$. With batter slope $1:1$, `reach` becomes $182\text{ m}$.
3. **Massive Evaluation Box**: The bounding box $[lo - reach, hi + reach]$ expands into a $400\text{ m} \times 400\text{ m}$ grid encompassing tens of thousands of cells.
4. **Unbounded Polygon Raycasts**: For every cell in that giant box, the code executes `Geometry2D.is_point_in_polygon(at, boundary)` and `Pasture3DRoadMesher.footprint_edge_at(at, boundary, heights)`. This accounts for **160.15 ms** of pure CPU freeze.

---

### Bottleneck 3: Unclipped Whole-Grid Foreign Earthwork Merging (`_merge_junction_earthwork`)
**Location:** [`project/addons/pasture_3d/roads/pasture3d_road_brush.gd:1215-1251`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_brush.gd#L1215-L1251)

When Road A meets Road B at an intersection:
1. `_merge_junction_earthwork` calls `b.earthwork_over(p_ground, p_gw, p_gh, p_min_x, p_min_z, p_vs)` on Road B.
2. In `earthwork_over`, `Pasture3DRoadGrader.grade` re-grades Road B's *entire multi-kilometer alignment* across all $186,624$ cells of the terrain.
3. Then `_merge_junction_earthwork` runs an unclipped loop over all $186,624$ cells comparing `absf(t - g) > absf(m - g)` in GDScript.
4. The actual intersection between Road A and Road B is a $20\text{ m} \times 20\text{ m}$ square ($\approx 400$ cells). Evaluating $186,624$ cells instead of $400$ cells represents a **$460\times$ work amplification**, costing **141.56 ms**.

---

### Bottleneck 4: Shared Layer Tile Invalidation Repaints All Mates (`_refresh_owner_rect`)
**Location:** [`project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:1662-1743`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd#L1662-L1743)

In `demo_road_network.tscn`, all 4 road brushes are assigned to the `"roads"` layer (`layer_owner = "roads"`).
1. When a spline point moves, `_refresh_owner_rect` computes `clip_box` by snapping the dirty bounding box to terrain tile boundaries (e.g. $64\text{ m}$ multiples).
2. The snapped `clip_box` encloses the 4-way crossroads tile.
3. Lines 1733–1742 iterate over `_tools_on_owner("roads")`. Because `Road`, `Road1`, and `Road2` all touch that tile, `s._overlaps_box(clip_box)` evaluates to `true` for all 3 sibling tools.
4. `_refresh_owner_rect` calls `_paint_into` sequentially on `Road1` (252 ms), `Road` (243 ms), and `Road2` (153 ms), totaling **735.58 ms** on the main thread.

---

### Bottleneck 5: Native C++ Disqualification by Junctions & Cascading Follow-Up Bakes
**Location:** [`project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:4176-4180`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd#L4176-L4180)

1. **Native C++ Disqualification**:
   ```gdscript
   if self is Pasture3DRoadBrush:
       var rb := self as Pasture3DRoadBrush
       var net := rb.road_network()
       if net != null and not net.junctions_for(rb.road_key()).is_empty():
           return false
   ```
   `_road_native_is_complete` returns `false` if a road has *any* junctions. As a result, roads with junctions are completely barred from using the multi-threaded, SIMD-accelerated C++ `stamp_road_line` kernel, falling back to slow interpreted GDScript loops.
2. **Cascading Ping-Pong Rebakes**:
   When Road 3's point moves, crossing junctions recalculate their elevation and arm tangents. In `resolve_junctions()`, Road, Road 1, and Road 2 find that `b.junction_digest() != b.last_junction_digest`. Each one invokes `schedule_junction_rebake()`. Because rebakes are scheduled as separate timer/idle events, they fire on successive frames, causing the editor to freeze for 700 ms, unfreeze for 1 frame, freeze for 700 ms, and unfreeze again.

---

## 3. Detailed Technical Specification & Remediation Phases

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                            INTERACTIVE EDIT PIPELINE                         │
│                                                                              │
│  Spline Drag                                                                 │
│  (Mouse Down)   ────────►  0.03 ms / frame (Interactive handles update)       │
│                                                                              │
│  Mouse Release  ────────►  Phase 4: Shared-Layer Spatial Pruning & Cache     │
│                            Phase 2: Localized Rise & Batter Evaluation       │
│                            Phase 3: Bounded Conflict Earthwork Overlap       │
│                            Phase 1: Apron Content Digest Cache               │
│                            Phase 5: Sub-Millimeter Jitter Deadband           │
│                                                                              │
│  Target Total Latency: < 95 ms (Single-frame, zero perceptible freeze)       │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

### Phase 1: Apron Content Digest Caching (`Pasture3DRoadChunkHost`)

#### Objective
Eliminate the 202 ms cost of `rebuild_aprons` by preserving existing apron meshes, collision shapes, and marking nodes when junction geometry and settings have not changed.

#### Architecture & Implementation
In [`Pasture3DRoadChunkHost`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_chunk_host.gd):
1. Introduce `_apron_cache: Dictionary` (mapping junction ID string -> apron record dictionary) and `_apron_digests: Dictionary` (mapping junction ID string -> 64-bit integer hash).
2. Define `_apron_digest(a: Dictionary, p_lift: float) -> int`:
   Hashes:
   - `a["center"]` (quantized to $0.001\text{ m}$)
   - `a["center_h"]` (quantized to $0.001\text{ m}$)
   - `a["boundary"]` coordinates
   - `a["heights"]` array
   - `a["material"]` instance ID
   - `p_lift`
   - `collision_enabled`
   - Markings inputs (`stop_lines`, `give_ways`, `crossings`, `connectors`)
3. In `rebuild_aprons(p_aprons: Array, p_lift: float)`:
   - Instead of calling `_clear()` indiscriminately:
   - Identify active junction IDs in `p_aprons`.
   - Remove and free aprons whose junction IDs are no longer present in `p_aprons`.
   - For each apron `a` in `p_aprons`:
     - Compute `digest = _apron_digest(a, p_lift)`.
     - If `_apron_digests.get(jid) == digest` and `_apron_cache.has(jid)`:
       - **Cache Hit**: Retain existing `MeshInstance3D`, markings, and collision shapes untouched!
     - Else:
       - **Cache Miss**: Free previous nodes for `jid`, construct new `MeshInstance3D`, generate collision shape, build markings, and record new digest.
4. **Performance Impact**: When moving a spline point on a connected road, at most 1 junction changes. 6 of the 7 aprons hit the cache in $0.01\text{ ms}$.
   - Apron rebuild drops from **202.07 ms** to **< 15 ms** on cache miss (1 junction) and **< 0.5 ms** when junction geometry is stationary.

---

### Phase 2: Localized Rise & Batter Evaluation (`_batter_junction_footprint`)

#### Objective
Eliminate the 160 ms cost of `grade_junction_footprints` by bounding terrain rise calculations and polygon distance evaluations strictly to the junction's local footprint neighborhood.

#### Architecture & Implementation
In [`Pasture3DRoadBrush._batter_junction_footprint`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_brush.gd#L1425-L1485):
1. **Local Rise Window**:
   Replace the global $187\text{k}$-cell `for idx in p_ground.size()` loop:
   ```gdscript
   # Determine initial local bounding box expanded by a conservative search radius (e.g. 35m)
   const MAX_LOCAL_BATTER_RADIUS: float = 35.0
   var local_ix0 := clampi(int(floor((lo.x - MAX_LOCAL_BATTER_RADIUS - p_min_x) / p_vs)), 0, p_gw - 1)
   var local_ix1 := clampi(int(ceil((hi.x + MAX_LOCAL_BATTER_RADIUS - p_min_x) / p_vs)), 0, p_gw - 1)
   var local_iz0 := clampi(int(floor((lo.y - MAX_LOCAL_BATTER_RADIUS - p_min_z) / p_vs)), 0, p_gh - 1)
   var local_iz1 := clampi(int(ceil((hi.y + MAX_LOCAL_BATTER_RADIUS - p_min_z) / p_vs)), 0, p_gh - 1)

   var rise := 0.0
   for liz in range(local_iz0, local_iz1 + 1):
       var lrow := liz * p_gw
       for lix in range(local_ix0, local_ix1 + 1):
           var gh: float = p_ground[lrow + lix]
           if is_finite(gh):
               rise = maxf(rise, maxf(gh - z_lo, z_hi - gh))
   ```
2. **Clamped Physical Batter Reach**:
   Enforce a maximum physical batter reach limit:
   ```gdscript
   var max_slope: float = minf(cut_batter, fill_batter)
   var reach: float = minf(rise / max_slope + verge, MAX_LOCAL_BATTER_RADIUS)
   ```
3. **Bounding Box Pre-Check Before Polygon Testing**:
   Inside the cell loop $[iz_0, iz_1] \times [ix_0, ix_1]$:
   - Check if the cell point `at` is farther than `reach` from the polygon's axis-aligned bounding box $[lo, hi]$.
   - If `at.x < lo.x - reach` or `at.x > hi.x + reach` or `at.y < lo.y - reach` or `at.y > hi.y + reach`, skip immediately.
   - Only call `Geometry2D.is_point_in_polygon` and `Pasture3DRoadMesher.footprint_edge_at` when the point is within the reach margin of the polygon.
4. **Performance Impact**:
   - Rise scan iterations drop from $1,306,368$ to $\approx 5,000$ ($260\times$ reduction).
   - Evaluated cells drop from thousands to a narrow ring around the junction polygon.
   - `grade_junction_footprints` drops from **160.15 ms** to **< 12 ms**.

---

### Phase 3: Bounded Crossing Earthwork Overlap (`_merge_junction_earthwork`)

#### Objective
Eliminate the 141 ms cost of foreign road earthwork re-grading by restricting partner earthwork calculations strictly to the localized intersection conflict zone.

#### Architecture & Implementation
In [`Pasture3DRoadBrush._merge_junction_earthwork`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_brush.gd#L1215-L1251):
1. **Identify Intersection Conflict Bounding Box**:
   For each crossing partner brush `b`:
   - Compute the union of bounding boxes of all crossing junctions shared between `self` and `b`.
   - Expand this box by `corridor_half_width + 15.0` (covering maximum possible batter reach).
   - Snap the box to terrain grid coordinates: $[c\_ix_0, c\_ix_1] \times [c\_iz_0, c\_iz_1]$.
2. **Clipped Foreign Grading via `earthwork_over_clipped`**:
   In `earthwork_over`:
   - Accept an optional `p_clip_box: AABB = AABB()`.
   - Forward `p_clip_box` to `Pasture3DRoadGrader.grade` via `clip_aabb`.
   - `Pasture3DRoadGrader.grade` already possesses native segment pruning and row/column clipping logic when given a clip box!
3. **Localized Array Merge**:
   - Instead of iterating through all $k \in [0, p\_out.size() - 1]$:
   - Iterate only $iz \in [c\_iz_0, c\_iz_1]$ and $ix \in [c\_ix_0, c\_ix_1]$:
     ```gdscript
     var k := iz * p_gw + ix
     var g: float = p_ground[k]
     var t: float = theirs[k]
     if not (is_finite(g) and is_finite(t)):
         continue
     var m: float = p_out[k]
     if not is_finite(m):
         continue
     if absf(t - g) > absf(m - g):
         p_out[k] = t
     ```
4. **Performance Impact**:
   - Foreign road grading is confined to $\sim 400$ cells instead of $186,624$ cells.
   - Array merge iterations drop from $186,624$ to $\sim 400$.
   - `_merge_junction_earthwork` drops from **141.56 ms** to **< 5 ms**.

---

### Phase 4: Shared-Layer Repaint Pruning & Stamp Cache Acceleration (`_refresh_owner_rect`)

#### Objective
Reduce the 735 ms cost of `_refresh_owner_rect` so that only the actively edited road repaints, while unchanged sibling roads on the shared `"roads"` layer are served instantly from cached stamps.

#### Architecture & Implementation
In [`Pasture3DTerrainBrush._refresh_owner_rect`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd#L1662-L1743):
1. **Distinguish Edited Tool from Sibling Layer Mates**:
   In `_refresh_owner_rect(owner, changed_ids, snap_all)`:
   - Identify the set of tools that own `changed_ids`.
   - Sibling tools on `owner` whose splines are NOT in `changed_ids` only need their cached stamp re-applied to the cleared tile area via `terrain.data.apply_sim_block(...)` if their stamp is valid and their geometry did not change.
2. **Stamp Cache Parity for Roads**:
   - In `Pasture3DRoadBrush`: ensure `_stamp_cache` stores the graded road footprint block.
   - When a sibling road overlaps the cleared `clip_box` but its curve, alignment, and junctions did not change, serve it via `apply_sim_block` in $0.15\text{ ms}$ instead of executing a full 250 ms GDScript road bake.
3. **Performance Impact**:
   - `Road1._paint_into`: 251 ms -> $0.2\text{ ms}$ (stamp replay).
   - `Road._paint_into`: 242 ms -> $0.2\text{ ms}$ (stamp replay).
   - `Road2._paint_into`: 153 ms -> $0.2\text{ ms}$ (stamp replay).
   - `_refresh_owner_rect` total time drops from **735.58 ms** to **< 60 ms** (only the actively edited road paints).

---

### Phase 5: Rebake Cascade Suppression & Junction-Aware Native C++ Acceleration

#### Objective
Eliminate multi-frame cascading rebakes and enable native C++ rasterization for roads with junctions.

#### Architecture & Implementation
1. **Sub-Millimeter Jitter Deadband in `junction_digest()`**:
   In [`Pasture3DRoadBrush.junction_digest`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_brush.gd#L1190-L1215):
   - Quantize elevation `z` to $0.005\text{ m}$ ($5\text{ mm}$).
   - Quantize arm directions and angles to $0.01\text{ rad}$.
   - Minor numerical rounding when solving intersecting splines will no longer trigger false-positive digest mismatches on unaffected partner roads.
2. **Coalesced Junction Rebake Scheduling**:
   In [`Pasture3DRoadBrush.schedule_junction_rebake`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_brush.gd#L1230-L1240):
   - Check if the road's current `junction_digest()` actually differs from `last_junction_digest` before calling `_schedule_refresh()`.
   - Prevent the ping-pong cascade where Road A rebakes Road B, which then rebakes Road A on the subsequent frame.
3. **Junction Suppression Intervals in Native C++ Rasterizer**:
   In [`src/pasture_3d_brush_raster.cpp`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/src/pasture_3d_brush_raster.cpp):
   - `stamp_road_line` already accepts `p_suppress: PackedByteArray` specifying intervals along the alignment where road grading should be suppressed!
   - Mark junction trim intervals in `p_suppress`.
   - Update `_road_native_is_complete` in `pasture3d_terrain_brush.gd` to permit native C++ rasterization for roads with junctions when footprints are separately stamped.

---

## 4. Invariants & Compatibility Guarantees

| Invariant | Guarantee & Mechanism |
|---|---|
| **`graph_path()` Parity** | The Terrain Node Graph receives the exact full-length `Pasture3DGraphPath` with identical coordinates, heights, and widths. Optimization changes only editor invalidation and rasterization. |
| **Bitwise Elevation & Mesh Parity** | Footprint and apron meshes match existing geometry to within $< 0.0001\text{ m}$. No visible seams or vertex popping occur at junction interfaces. |
| **Collision Continuity** | Collision shapes in `Pasture3DRoadChunkHost` maintain zero-lift placement and provide seamless raycast surfaces across road ribbons and junction aprons. |
| **Lane Graph & Routing** | `Pasture3DRoadLaneSolver` and `Pasture3DRoadRoute` retain all solved connector curves, turn classifications, and topological connectivity. |
| **Undo / Redo Safety** | Editor gizmo moves preserve full undo/redo stacks. All cache invalidations correctly respond to undo and redo operations without leaving ghost terrain artifacts. |

---

## 5. Performance Budgets & Verification Plan

### 5.1 Performance Targets

| Metric | Before Optimization | Target Budget |
|---|---|---|
| **Apron Rebuild (`rebuild_aprons`)** | $202.07\text{ ms}$ | **$< 1.0\text{ ms}$** (Digest hit) / **$< 15\text{ ms}$** (Miss) |
| **Footprint Batter (`grade_junction_footprints`)** | $160.15\text{ ms}$ | **$< 12.0\text{ ms}$** |
| **Earthwork Merge (`_merge_junction_earthwork`)** | $141.56\text{ ms}$ | **$< 5.0\text{ ms}$** |
| **Layer Invalidation (`_refresh_owner_rect`)** | $735.58\text{ ms}$ | **$< 60.0\text{ ms}$** |
| **Total Synchronous Frame Latency** | **$1,013.55\text{ ms}$** | **$< 95.0\text{ ms}$** |
| **Cascading Multi-Frame Freezes** | **$> 1,500\text{ ms}$ (2–3 frames)** | **$0\text{ ms}$ (0 frames)** |

### 5.2 Verification Gates & Test Suite
1. **`RoadInteractivePerfGate` (`project/bench/RoadInteractivePerfGate.gd`)**:
   - Instantiates `demo_road_network.tscn`.
   - Simulates moving a control point on `Road3` at the 4-way intersection.
   - Asserts:
     - Total synchronous execution time $< 150\text{ ms}$ (headless bench ceiling).
     - `rebuild_aprons` executes in $< 1.0\text{ ms}$ on unchanged aprons.
     - Follow-up frames generate zero `schedule_junction_rebake` calls.
     - Heightfield and apron vertex coordinates match ground truth baseline to $\le 0.001\text{ m}$.
2. **Subsystem Regression Test Gates**:
   - `RoadEndConnectionGate` (P10 endpoint connection topology) — must remain 100% green.
   - `RoadCostGate` (S1–S12 cost reduction & stamp caching) — must remain 100% green.
   - `RoadJunctionGate` (Junction solver & planar kernels) — must remain 100% green.
   - `RoadLaneGraphGate` (Lane connectors & graph topology) — must remain 100% green.
   - `RoadRouteGate` (A* road routing & navigation) — must remain 100% green.
