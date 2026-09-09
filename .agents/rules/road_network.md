# Pasture3D Road & Junction Network Rules

## 1. Interactive Performance & Invalidation Invariants

When implementing or modifying road brushes, junction solvers, networks, or chunk hosts:

### A. Apron Surface Caching & Mesh Reconciliation
- **Digest-Based In-Place Retention**: `Pasture3DRoadChunkHost.rebuild_aprons` must never unconditionally clear all apron meshes (`_clear()`). It must reconcile existing aprons via stable geometry digests (`_apron_digest`).
- **Zero Allocation on Unchanged Aprons**: If an apron's digest matches, retain its `MeshInstance3D`, markings, and `ConcavePolygonShape3D` nodes in-place without scene tree reparenting.
- **Spec Memoization**: In `Pasture3DRoadNetwork.build_junction_surfaces`, consult `_apron_spec_cache` and quantized hashes *before* invoking expensive road alignment evaluations (`b.build_run()`).

### B. Localized Conflict Subgrids & Formation Step Scaling
- **Subgrid Cropping**: When merging crossing road earthwork in `_merge_junction_earthwork`, never re-grade foreign roads over the entire terrain grid. Extract a localized subgrid (e.g. $60 \times 60$ cells around the intersection) and evaluate `earthwork_over` strictly within the cropped subgrid.
- **Localized Batter Reach**: In `_batter_junction_footprint`, cap vertical rise searches to a local radius (`MAX_LOCAL_BATTER_RADIUS = 35.0 m`) to prevent distant terrain peaks from inflating the evaluation box. Pre-cull candidate cells using radial distance (`dx*dx + dy*dy > reach_sq`) before calling `is_point_in_polygon`.
- **Proportional Formation Mask Stepping**: Scale spline evaluation steps with radius (`maxf(PROTECT_STEP, radius * 0.4)`) and apply row culling (`dy2 > r2`) to avoid redundant cell writes.

### C. Jitter Deadbands & Cascade Suppression
- **Deadbanded Digests**: Quantize all arm elevations, trim lengths, and tangents in `Pasture3DRoadBrush.junction_digest()` using `%.3f` (1 mm precision) and $0.01\text{ rad}$. Floating-point IEEE 754 epsilon drift must never invalidate partner road digests.
- **Guarded Rebake Scheduling**: In `schedule_junction_rebake()`, verify that the current `junction_digest()` strictly differs from `last_junction_digest` before scheduling a refresh. Never allow cross-road ping-pong rebake cascades across frames.

---

## 2. Regression Gate & Test Suite Standards

When authoring or modifying bench gates in `project/bench/`:

### A. Demo Scene Sandbox Isolation
- **Redirect Data Directory**: When loading `demo_road_network.tscn` or other demo scenes, immediately redirect `terrain.data_directory = "user://..."` to prevent terrain auto-saves from modifying `res://demo/data/...` region files.
- **Restore Mutated Geometry**: If test fixtures mutate control points or curve positions on loaded scenes, restore them to their original positions before calling `scene.queue_free()`.
- **Clean Git Status Invariant**: Running any test suite or benchmark gate must leave `git status` 100% clean with zero modified demo or scene assets.

### B. Strict GDScript Static Typing
- **Explicit Return Types**: In Godot 4.7 headless bench scripts, avoid untyped type inference `:=` on engine calls without static return hints (e.g. `scene.find_child()`, `net.road_brushes()`, `packed.instantiate()`). Always explicitly type local variables (`var scene: Node = ...`, `var host: Pasture3DRoadChunkHost = ...`) to prevent parse reload failures.
