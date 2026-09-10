# Pasture3D Road System — Spline Edit Localization, Complex Junctions & Sharp Turn Smoothing Specification

**Document Version:** 1.0  
**Target Engine:** Godot 4.7+ / GDExtension (C++ / GDScript)  
**Status:** SPECIFICATION READY FOR REVIEW  
**Builds on:** `PASTURE3D_ROAD_SIMCADE_UPGRADE_SPEC.md`, `PASTURE3D_ROAD_JUNCTION_PAINT_AND_SMOOTHING_SPEC.md`, `PASTURE3D_ROAD_BRUSH_PERF_SPEC.md`  

---

## 1. Executive Summary & Scope

Following the successful completion of the Simcade Road Upgrade (Phases P0–P9h), this specification addresses three critical geometric and performance deficiencies identified in the road authoring and meshing pipelines:

1. **Spline Edit Full Grid Rebake Regression**:
   - *Symptom*: Translating or modifying a single spline control point triggers a global grid rasterization and an unconditional whole-world `composite_regions()` push across the entire terrain, rather than updating only the localized dirty bounding box.
   - *Objective*: Restore true sub-span dirty-rect processing ($O(W_{\text{dirty}} \times H_{\text{dirty}})$ rather than $O(W_{\text{spline}} \times H_{\text{spline}})$) for alignment solving, ground height queries, rasterization, stamp caching, and GPU region composition.

2. **Intersection Geometry Misalignment on Multi-Road (>2 Roads) & Acute Crossings**:
   - *Symptom*: When more than two roads intersect (e.g. 3-way Y-junctions, 5-arm roundabouts, 6-arm multi-crossings) or when two roads cross at acute angles ($\phi < 45^\circ$), junction boundaries tear open, cut faces detach from approach road ribbons, and large triangular gaps or overlapping surfaces occur.
   - *Root Cause*: The fallback to `Geometry2D.convex_hull(out)` discards cut-face centerline and corner vertices; radial fillet allowance ($R/\tan(\phi/2)$) diverges and contaminates entire road alignments symmetrically; and unconstrained Delaunay triangulation fails to conform to boundary chords.
   - *Objective*: Replace the destructive convex-hull fallback with an invariant cut-face-preserving boundary solver, bounded asymmetric per-arm mitring, and boundary-conforming interior patch generation.

3. **Sharp Corner Overlap & Ribbon Z-Fighting (Swallowtail Singularities)**:
   - *Symptom*: When a road spline turns sharply with a radius of curvature smaller than the road's half-width ($R < w_{\text{half}}$), the parallel offset curves along the inner edge invert and travel backwards relative to the centerline. This creates self-overlapping quad rings, inverted triangle winding, and severe coplanar Z-fighting.
   - *Objective*: Provide automatic curvature detection along splines, interactive/procedural tangent-relaxation smoothing ($R \ge R_{\min}$), and an ironclad mesher-level swallowtail clipping and mitring guard that guarantees zero overlapping quads regardless of spline geometry.

---

## 2. Issue 1: Localized Spline Edit & Dirty-Rect Rasterization

### 2.1 Problem Analysis & Regression Mechanics

In `pasture3d_road_brush.gd` and `pasture3d_road_network.gd`, several compounding flaws cause a local spline edit to degrade into an engine-wide full bake:

1. **Unclipped Grid Snapping**:
   In `Pasture3DRoadBrush._paint_flat_footprint(path)` (`lines 590–597`):
   ```gdscript
   var b := _snapped_bounds(_spline_footprint_aabb(path), vs)
   var gw := int(round((b[1] - b[0]) / vs)) + 1
   var gh := int(round((b[3] - b[2]) / vs)) + 1
   ```
   The bounding box `b` and dimensions `gw, gh` are computed unconditionally from the *entire* spline's footprint (`_spline_footprint_aabb(path)`). Even when `_clip_aabb` is set (e.g., a $20\text{ m} \times 20\text{ m}$ box around a moved control point on a $3\text{ km}$ mountain pass), `gw \times gh` allocates hundreds of thousands or millions of cells.

2. **Global Vertical Alignment & Ground Sampling**:
   In lines 604–637:
   ```gdscript
   var cum := _plan_cum()
   var total: float = cum[cum.size() - 1]
   var n_s := maxi(int(ceil(total / ds)) + 1, 2)
   ground = terrain.data.get_height_below_along_plan(_layer_id, plan, cum, ds, n_s)
   alignment = Pasture3DRoadAlignmentSolver.solve_with_plan(...)
   ```
   The brush queries the terrain heightfield and re-solves the vertical alignment for all $N_s$ samples over the entire road length $[0, L]$, rather than restricting the query and solve to the affected arc-length interval $[s_{\min}, s_{\max}]$.

3. **Stamp Cache Invalidation on Clipped Bakes**:
   In lines 700–701:
   ```gdscript
   if not bool(out.get("clipped", true)) and vals_out.size() == gw * gh:
       _store_stamp_cache(...)
   else:
       _stamp_cache.erase(path.get_instance_id())
   ```
   A clipped bake deliberately *erases* the cached whole-spline stamp block. Consequently, the next repaint (or any query by an adjacent brush) finds no cache and is forced to re-rasterize the entire road from scratch.

4. **Global GPU Composition in Road Network**:
   In `Pasture3DRoadNetwork._composite(p_terrains)` (`lines 1376–1380`):
   ```gdscript
   func _composite(p_terrains: Dictionary) -> void:
       for t in p_terrains.values():
           if t.data != null and t.data.has_method("composite_regions"):
               t.data.composite_regions()
   ```
   `composite_regions()` recomposites *every active region* in the entire terrain world and pushes every height and control map texture to the GPU. For dirty-rect updates, `t.data.composite_area(clip_box, true)` was specifically provided in `Pasture3DData` but was bypassed here.

5. **Full Chunk Re-Meshing**:
   In `Pasture3DRoadChunkHost.rebuild(p_brush)`:
   All spans along the entire road are rebuilt into new `MeshInstance3D` nodes and `ArrayMesh` surfaces regardless of whether the chunk's bounding box intersects the edited region.

---

### 2.2 Mathematical & Algorithmic Design

```
                     World Spline AABB
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│                    Dirty-Rect Clip AABB                     │
│               ┌───────────────────────┐                     │
│   Road Polyline=======[s_min]=========[s_max]===============│
│               │                       │                     │
│               │  Quantized Sub-Grid   │                     │
│               │  gw_clip x gh_clip    │                     │
│               └───────────────────────┘                     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

#### 2.2.1 Quantized Grid Intersection
Let the spline world footprint AABB be $\mathcal{B}_{\text{spline}} = [X_{\min}, Z_{\min}, X_{\max}, Z_{\max}]$.  
Let the dirty clip box be $\mathcal{B}_{\text{clip}} = [C_{x0}, C_{z0}, C_{x1}, C_{z1}]$.

When $\mathcal{B}_{\text{clip}}$ is non-empty:
$$\mathcal{B}_{\text{active}} = \mathcal{B}_{\text{spline}} \cap \mathcal{B}_{\text{clip}}$$
If $\mathcal{B}_{\text{active}} = \emptyset$, the spline does not intersect the dirty box and early-returns immediately ($0$ cost).

The snapped bounds are aligned to the terrain vertex spacing $v_s$:
$$\begin{aligned}
x_0 &= \lfloor (\mathcal{B}_{\text{active}}.X_{\min} - \text{pad}) / v_s \rfloor \cdot v_s \\
x_1 &= \lceil (\mathcal{B}_{\text{active}}.X_{\max} + \text{pad}) / v_s \rceil \cdot v_s \\
z_0 &= \lfloor (\mathcal{B}_{\text{active}}.Z_{\min} - \text{pad}) / v_s \rfloor \cdot v_s \\
z_1 &= \lceil (\mathcal{B}_{\text{active}}.Z_{\max} + \text{pad}) / v_s \rceil \cdot v_s
\end{aligned}$$
$$g_w = \text{round}\left(\frac{x_1 - x_0}{v_s}\right) + 1, \quad g_h = \text{round}\left(\frac{z_1 - z_0}{v_s}\right) + 1$$
This shrinks the rasterization grid from $O(L_{\text{road}}^2)$ to $O(L_{\text{dirty}}^2)$, achieving a $10\times$ to $100\times$ reduction in cell allocations.

#### 2.2.2 Arc-Length Sub-Span Projection
Given $\mathcal{B}_{\text{active}}$, determine the minimal arc-length interval $[s_{\min}, s_{\max}] \subseteq [0, L_{\text{total}}]$ that influences the grid:
$$s_{\min} = \max\left(0.0, \min_{i \in \text{segs} \cap \mathcal{B}_{\text{active}}} s(i) - D_{\text{corridor}}\right)$$
$$s_{\max} = \min\left(L_{\text{total}}, \max_{i \in \text{segs} \cap \mathcal{B}_{\text{active}}} s(i+1) + D_{\text{corridor}}\right)$$
where $D_{\text{corridor}} = w_{\text{half}} + w_{\text{shoulder}} + w_{\text{batter}}$.

- **Localized Ground Sampling**: Sample `get_height_below_along_plan` only for sample indices $k \in [\lfloor s_{\min} / ds \rfloor, \lceil s_{\max} / ds \rceil]$.
- **Local Alignment Splice**: When an existing `last_alignment` exists, reuse the unaffected prefix $[0, s_{\min})$ and suffix $(s_{\max}, L_{\text{total}}]$, solving the vertical profile only over $[s_{\min}, s_{\max}]$ with $C^1$ boundary conditions matched at $s_{\min}$ and $s_{\max}$.

#### 2.2.3 Stamp Cache Sub-Block Preservation
Rather than erasing `_stamp_cache[pid]` upon a clipped bake:
1. Retain the existing full-spline cached buffer $V_{\text{full}}$ of dimensions $W_{\text{full}} \times H_{\text{full}}$.
2. Execute native rasterization with `stamp_road_line` targeted to $\mathcal{B}_{\text{active}}$.
3. In-place update the overlapping sub-rectangle of $V_{\text{full}}$ using the newly written finite float values:
   $$V_{\text{full}}(x, z) = V_{\text{clip}}(x - x_0, z - z_0) \quad \forall (x, z) \in \mathcal{B}_{\text{active}} \text{ where } V_{\text{clip}} \ne \text{NaN}$$
4. If no full-spline cache exists yet, defer full caching until the next unclipped refresh or save action.

#### 2.2.4 Scoped Terrain Dirty-Rect GPU Composition
In `Pasture3DRoadNetwork.paint_roads()` and `_composite()`:
1. Accumulate the union bounding box $\mathcal{A}_{\text{dirty}} = \bigcup_{b \in \text{repaint}} \mathcal{B}_{\text{dirty}}(b)$.
2. If $\mathcal{A}_{\text{dirty}}$ is finite and non-empty:
   ```gdscript
   t.data.composite_area(A_dirty, false)
   t.data.update_maps(MAPTYPE_HEIGHT, false, false) # push only affected region textures
   ```
3. Only invoke `t.data.composite_regions()` during explicit whole-layer rebuilds or scene loads.

#### 2.2.5 Chunk Host Selective Invalidation
In `Pasture3DRoadChunkHost`:
1. Index chunks by arc-length interval $[s_{\text{start}}, s_{\text{end}}]$ and world AABB.
2. In `rebuild_dirty(p_brush, p_dirty_aabb)`:
   - Identify only chunks whose world AABB intersects `p_dirty_aabb`.
   - Regenerate `ArrayMesh` surfaces and colliders *only* for the affected chunks.
   - Leave untouched chunks running with their existing GPU mesh buffers.

---

## 3. Issue 2: Robust Multi-Road & Acute Junction Boundary Solver

### 3.1 Problem Analysis: Why Intersections Struggle with >2 Roads & Sharp Angles

```
               Acute Crossing (phi < 30°)
                    Road A \        / Road B
                            \      /
                             \    /
                              \  /
  Standard Fillet Diverges:    \/  Apex Cut Face Crosses Over!
  tan(phi/2) -> 0              /\
  Allowance -> 50m+           /  \
                             /    \
                            /      \
```

1. **Destructive Convex-Hull Fallback**:
   In `pasture3d_road_mesher.gd` (`lines 709–718`):
   ```gdscript
   if not _is_simple(out):
       var hull := Geometry2D.convex_hull(out)
       if hull.size() > 1 and hull[0].distance_to(hull[hull.size() - 1]) <= 1e-4:
           hull.remove_at(hull.size() - 1)
       return hull
   ```
   When $>2$ roads meet or when two roads cross at an acute angle ($\phi < 45^\circ$), adjacent fillets or cut faces overlap, causing `_is_simple(out)` to return `false`.
   `Geometry2D.convex_hull(out)` creates catastrophic failures:
   - **Centerline Crown Vertex Removal**: The cut face has three vertices: $[a_{\text{cw}}, a_{\text{center}}, a_{\text{ccw}}]$. Because $a_{\text{center}}$ is collinear between the two corners, `convex_hull` drops it.
   - **Concave Corner Severing**: Any road arm that enters a concave valley between two other arms is completely bypassed by the convex hull chord. The boundary cuts across the road, leaving a triangular hole between the junction apron and the road ribbon.
   - **Seam Disconnect**: The approach road ribbon terminates at the exact 3D coordinates of $[a_{\text{cw}}, a_{\text{center}}, a_{\text{ccw}}]$. The junction polygon now connects to arbitrary hull chords, producing visible gaps, tears, and severe Z-fighting.

2. **Divergent Radial Fillet Allowance ($R / \tan(\phi/2)$)**:
   In `Pasture3DRoadMesher.fillet_allowance` (`line 643`):
   $$A(\phi) = \frac{R}{\tan(\phi / 2)}$$
   As $\phi \to 0$, $A(\phi) \to \infty$. At $\phi = 20^\circ$, $A(20^\circ) = 5.67 \cdot R \approx 45.4\text{ m}$ for $R = 8\text{ m}$.
   In `pasture3d_road_junction_solver.gd:586`:
   ```gdscript
   out[p_arm_roads[ia]] = maxf(out[p_arm_roads[ia]], a)
   out[p_arm_roads[ib]] = maxf(out[p_arm_roads[ib]], a)
   ```
   This $45\text{ m}$ trim is applied to the *entire road* symmetrically. The opposite arm of that road (which may point into open space or a $90^\circ$ cross-street) also gets trimmed back by $45\text{ m}$, blowing open an enormous void.

3. **Multi-Arm Closely Spaced Corner Collapse**:
   For $N \ge 3$ intersecting roads (e.g. 5 or 6 radial arms):
   The angular separation between adjacent arms $\phi_i = \angle(\mathbf{d}_{i+1}) - \angle(\mathbf{d}_i)$ can be very small ($25^\circ$ to $40^\circ$).
   Because road ribbons have finite widths ($2 w_{\text{half}} \approx 8\text{ m}$), the CCW edge of arm $i$ and the CW edge of arm $i+1$ cross at a point $c$ that lies *behind* the cut faces ($s_a < 0$ or $s_b < 0$).
   `_append_fillet` evaluates ray intersections with negative room, causing the boundary loop to invert, fold over, and trigger the convex hull fallback.

4. **Unconstrained Delaunay Triangulation Boundary Leakage**:
   In `build_coons_patch` (`pasture3d_road_mesher.gd:1077`):
   The interior grid points and boundary points are triangulated with unconstrained Delaunay:
   `raw_tris := Geometry2D.triangulate_delaunay(all_pts)`
   Unconstrained Delaunay does *not* constrain boundary edges. When the boundary has acute concavities or narrow fillets, Delaunay triangles can span across the exterior, or boundary edges fail to exist in the mesh. The filtering heuristic (`is_point_in_polygon(midpoint)`) drops valid boundary triangles or leaves jagged gaps along the cut faces.

---

### 3.2 Mathematical Formulation & Geometric Architecture

```
                    Watertight Multi-Arm Junction Architecture
                    
                    Approach Road A Ribbon
                   [A_cw]──[A_center]──[A_ccw]   <- FIXED CUT FACE INVARIANT
                     │                     │
                     │  Asymmetric Trim    │
                     │  Decoupled Per-Arm  │
                     ▼                     ▼
              ┌───────────────────────────────────┐
              │    Mitred Corner Return Arc       │
              │    Clamped tan_d <= Max Mitre     │
              │                                   │
              │   Constrained Conforming Patch    │
              │   Exact C1 Coons Surface          │
              │   Zero Radial Fan Ridge Creases   │
              │                                   │
              └───────────────────────────────────┘
                     ▲                     ▲
                     │  Asymmetric Trim    │
                     │  Decoupled Per-Arm  │
                     │                     │
                   [B_ccw]──[B_center]──[B_cw]   <- FIXED CUT FACE INVARIANT
                    Approach Road B Ribbon
```

#### 3.2.1 Invariant: Fixed Cut-Face Preservation
**Core Invariant**: Under no circumstances may a cut face $[a_{\text{cw}}, a_{\text{center}}, a_{\text{ccw}}]$ be removed, simplified, or replaced by a convex hull chord.
Every approach road terminates at:
$$\mathbf{p}_{\text{cw}} = \mathbf{c} + \mathbf{d} \cdot \text{trim} - \mathbf{n} \cdot w_{\text{half}}$$
$$\mathbf{p}_{\text{center}} = \mathbf{c} + \mathbf{d} \cdot \text{trim}$$
$$\mathbf{p}_{\text{ccw}} = \mathbf{c} + \mathbf{d} \cdot \text{trim} + \mathbf{n} \cdot w_{\text{half}}$$
The junction boundary polygon $\mathcal{P}_{\text{boundary}}$ *must* contain the exact sequence $(\mathbf{p}_{\text{cw}}, \mathbf{p}_{\text{center}}, \mathbf{p}_{\text{ccw}})$ for every arm.

#### 3.2.2 Asymmetric Decoupled Per-Arm & Per-Corner Trims
1. **Decouple Arm Trims from Road Trims**:
   Replace the scalar `trim_backs[road_idx]` with per-arm trim values `arm_trims[arm_idx]`. A road crossing a junction has two distinct arms (forward and backward); each arm calculates its trim independently based only on its immediate angular neighbors.
2. **Mitred Crossing Trim Cap**:
   For two arms crossing at angle $\phi$:
   $$\text{trim}_{\text{geom}} = \min\left(\frac{w_{\text{other}}}{\sin(\max(\phi, \phi_{\min}))}, \text{TRIM\_CAP\_FACTOR} \cdot w_{\text{arm}}\right)$$
   where $\text{TRIM\_CAP\_FACTOR} = 2.5$. Even at a $10^\circ$ crossing, an $8\text{ m}$ wide road is trimmed back at most $2.5 \times 4.0 = 10.0\text{ m}$ from the junction center, preventing runaway 50m+ voids.

#### 3.2.3 Bounded Mitred Corner Fillet Algorithm
In `_append_fillet(out, a_ccw, da, b_cw, db, radius, segments)`:
Let $\mathbf{d}_a, \mathbf{d}_b$ be the outward arm directions with angle $\phi = \arccos(\mathbf{d}_a \cdot \mathbf{d}_b)$.
1. **Ray Intersection & Room Test**:
   Intersect rays $\mathbf{r}_a(t) = \mathbf{a}_{\text{ccw}} + t \mathbf{d}_a$ and $\mathbf{r}_b(u) = \mathbf{b}_{\text{cw}} + u \mathbf{d}_b$.
   Compute distances $s_a = (\mathbf{a}_{\text{ccw}} - \mathbf{c}) \cdot \mathbf{d}_a$ and $s_b = (\mathbf{b}_{\text{cw}} - \mathbf{c}) \cdot \mathbf{d}_b$.
2. **Acute & Negative Room Handling**:
   - If $s_a \le 0$ or $s_b \le 0$ (the cut faces overlap or sit ahead of the intersection point), or if $\phi < 30^\circ$:
     Do *not* attempt a circular arc that would loop backward.
     Compute the **Mitre Apex Point**:
     $$\mathbf{m} = \frac{1}{2}\left(\mathbf{a}_{\text{ccw}} + \mathbf{b}_{\text{cw}}\right)$$
     Insert a direct mitred transition $[\mathbf{a}_{\text{ccw}}, \mathbf{m}, \mathbf{b}_{\text{cw}}]$. This preserves a simple, non-self-intersecting polygon boundary and prevents loops.
3. **Clamped Arc Fillet**:
   When $s_a > 0$ and $s_b > 0$:
   $$\text{room} = \min(s_a, s_b)$$
   $$t_d = \min\left(\frac{R}{\tan(\phi/2)}, \text{room} \cdot 0.95\right)$$
   $$R_{\text{eff}} = t_d \cdot \tan(\phi/2)$$
   Generate the smooth fillet arc from $\mathbf{t}_a = \mathbf{c} + \mathbf{d}_a t_d$ to $\mathbf{t}_b = \mathbf{c} + \mathbf{d}_b t_d$.

#### 3.2.4 Boundary-Conforming Triangulation (Constrained Patch Meshing)
To guarantee that the junction apron mesh meets the road ribbons with zero gaps:
1. **Boundary Constraint Enforcement**:
   Replace unconstrained Delaunay with **Boundary-Conforming Ear-Clipping + Interior Grid Refinement**:
   - Step 1: Subdivide the polygon boundary $\mathcal{P}_{\text{boundary}}$ by inserting the interior Coons grid vertices.
   - Step 2: Perform constrained triangulation using Godot's `Geometry2D.triangulate_polygon(p_boundary)`. Because `triangulate_polygon` is a constrained ear-clipping algorithm, every boundary segment is guaranteed to be an explicit edge of the mesh!
   - Step 3: For interior density (to support the smooth Coons height variation), insert regular interior grid vertices and split the containing ear-clipped triangles locally via Delaunay edge flips that preserve boundary constraints (Constrained Delaunay Triangulation).
2. **Height Blending with Normal Continuity**:
   Heights on the boundary vertices are assigned directly from the owning arm's cut face ($[a_{\text{cw}}, a_{\text{center}}, a_{\text{ccw}}]$). Interior vertices evaluate `coons_patch_height_at(p, p_center, p_arm_faces, p_center_h)` with inverse-quartic weights, guaranteeing $C^1$ tangential and normal slope matching.

---

## 4. Issue 3: Curvature-Bounded Spline Smoothing & Ribbon Overlap Elimination

### 4.1 Problem Analysis: Differential Geometry of Ribbon Inversion

Let the road centerline be a 2D curve $\mathbf{r}(s) \in \mathbb{R}^2$ parameterized by arc length $s$, with unit tangent $\mathbf{t}(s) = \mathbf{r}'(s)$ and unit normal $\mathbf{n}(s) = (-t_y(s), t_x(s))$.  
The Frenet-Serret formulas in 2D give:
$$\frac{d\mathbf{t}}{ds} = \kappa(s) \mathbf{n}(s), \quad \frac{d\mathbf{n}}{ds} = -\kappa(s) \mathbf{t}(s)$$
where $\kappa(s)$ is the signed curvature, and $R(s) = 1 / |\kappa(s)|$ is the radius of curvature.

```
                           Cusp / Swallowtail Singularity
                               
                               Centerline r(s)
                           ───────────────────────>
                                \   R(s)   /
                                 \        /
                                  \      /  Center of Curvature (Focal Point)
                                   \    /
                           ═════════\══/══════════ Inner Edge Curve r_u(s)
                                     \/
                                     /\  <- Inverted Swallowtail Overlap!
                                    /  \    Speed d r_u / ds < 0
                                   /    \   Coplanar Triangles Z-Fight!
```

A parallel offset curve at lateral distance $u \in [-w_{\text{half}}, w_{\text{half}}]$ is:
$$\mathbf{r}_u(s) = \mathbf{r}(s) + u \cdot \mathbf{n}(s)$$
Differentiating with respect to $s$:
$$\frac{d\mathbf{r}_u}{ds} = \frac{d\mathbf{r}}{ds} + u \frac{d\mathbf{n}}{ds} = \mathbf{t}(s) - u \kappa(s) \mathbf{t}(s) = (1 - u \kappa(s)) \mathbf{t}(s)$$

Notice the critical scaling factor:
$$\sigma(s, u) = 1 - u \kappa(s)$$
- When $\kappa(s) > 0$ (a turn to the left) and $u > 0$ (the inner left edge):
  - If $u < 1/\kappa(s) = R(s)$: $\sigma(s, u) > 0$. The inner curve advances forward monotonically.
  - If $u = R(s)$: $\sigma(s, u) = 0$. The inner curve collapses to a stationary point (a **cusp singularity**).
  - If $u > R(s)$ (i.e. $R(s) < w_{\text{half}}$): $\sigma(s, u) < 0$. **The inner curve moves backwards!**

When $\sigma(s, u) < 0$, the inner boundary loops back over itself, producing a classical **swallowtail caustic**:
1. Quad rings $(s_i \to s_{i+1})$ invert their geometric orientation.
2. The inner triangles of ring $i$ and ring $i+1$ overlap the exact same XZ spatial footprint.
3. Because road ribbons are generated with uniform vertical offset (`DEPTH_LIFT = 0.02`), these overlapping quads are strictly coplanar, producing severe, shimmering **Z-fighting** across the entire corner apex.
4. Generated concave collision meshes contain self-intersections, trapping simulation vehicles or causing physics engine depenetration glitches.

---

### 4.2 Multi-Tier Solution Architecture

To solve this completely, Pasture3D implements three defensive tiers:
1. **Tier A: Curvature Detection & Diagnostics** (identifying violations along authoring splines).
2. **Tier B: Spline Tangent Smoothing & Transition Spirals** (procedurally and interactively preventing $R < R_{\min}$).
3. **Tier C: Mesher Swallowtail Clipping & Mitring** (ironclad geometric guard ensuring the mesher never emits overlapping geometry even on pathological splines).

```
   [Authoring / Spline Level]
          │
          ▼
   Tier A: Curvature Detector (kappa(s), R(s)) 
          │  Asserts R(s) >= R_min = 1.2 * w_half
          │  Flags Sharp Apexes in Inspector / Gizmo
          ▼
   Tier B: Spline Smoothing & Tangent Relaxation
          │  - Interactive: Inspector "Smooth Sharp Corners" action
          │  - Procedural: Resampling Curvature Filter (Chaikin / Clothoid Easing)
          ▼
   [Mesher / Geometry Level]
          │
          ▼
   Tier C: Swallowtail Clipping & Mitring (Mesher Guard)
             Detects Inner Edge Velocity Inversion: (v_{i+1} - v_i) · t_i <= 0
             Collapses Inverted Quad Loop to Miter Apex
             --> ZERO Overlapping Quads, ZERO Z-Fighting
```

---

### 4.3 Detailed Algorithms

#### 4.3.1 Tier A: Spline Curvature Detection & Diagnostics
Along the resampled plan polyline $\mathbf{p}_0, \mathbf{p}_1, \dots, \mathbf{p}_{n-1}$ with step $ds$:
At each interior point $i \in [1, n-2]$:
$$\mathbf{t}_{i-1} = \frac{\mathbf{p}_i - \mathbf{p}_{i-1}}{\|\mathbf{p}_i - \mathbf{p}_{i-1}\|}, \quad \mathbf{t}_i = \frac{\mathbf{p}_{i+1} - \mathbf{p}_i}{\|\mathbf{p}_{i+1} - \mathbf{p}_i\|}$$
$$\Delta \theta_i = \text{atan2}(\mathbf{t}_{i-1} \times \mathbf{t}_i, \mathbf{t}_{i-1} \cdot \mathbf{t}_i)$$
$$\kappa_i = \frac{\Delta \theta_i}{\frac{1}{2}(\|\mathbf{p}_i - \mathbf{p}_{i-1}\| + \|\mathbf{p}_{i+1} - \mathbf{p}_i\|)}, \quad R_i = \frac{1}{|\kappa_i|}$$

- **Threshold**: A corner is flagged as *critical* if:
  $$R_i < R_{\text{crit}} = w_{\text{half}} + w_{\text{shoulder}} + \text{margin} \quad (\approx 1.2 \cdot w_{\text{half}})$$
- **Reporting**:
  - `Pasture3DRoadBrush.detect_sharp_corners() -> Array[Dictionary]` returns `[{ "s": float, "radius": float, "point": Vector3, "severity": float }]`.
  - In editor builds, render a warning marker on the spline gizmo at each sharp apex with the local radius displayed.

#### 4.3.2 Tier B: Spline Smoothing & Tangent Relaxation
1. **Interactive Control-Point Relaxation ("Smooth Sharp Corners")**:
   When invoked via the inspector button on `Pasture3DRoadBrush`:
   - For each control point $k$ where the apex radius $R < R_{\text{crit}}$:
     - If the `Curve3D` point has zero handles (linear vertex), insert cubic Bézier control handles $\mathbf{h}_{\text{in}}, \mathbf{h}_{\text{out}}$ aligned with the bisector tangent, sized to achieve $R \ge R_{\text{crit}}$.
     - If handles exist but are too tight, extend or reorient the handles to relax curvature.
   - Records a single undoable action (`UndoRedo`) so user edits can be reverted cleanly.

2. **Procedural Curvature-Clamping Filter on Resampled Plan**:
   In `Pasture3DUtil.resample_plan` or `_resample_plan`:
   - Execute an iterative 3-point smoothing pass on the 2D polyline vertices for segments where $|\kappa_i| > \kappa_{\max} = 1 / R_{\text{crit}}$:
     $$\mathbf{p}_i^* = (1 - 2\omega)\mathbf{p}_i + \omega(\mathbf{p}_{i-1} + \mathbf{p}_{i+1})$$
     with relaxation factor $\omega = 0.25$ (Chaikin subdivision corner rounding).
   - Recalculate cumulative arc lengths `cum` to preserve exact monotonic length.

#### 4.3.3 Tier C: Mesher Swallowtail Clipping & Mitring (Geometric Guard)
Even if an un-smoothed sharp spline is fed to `Pasture3DRoadMesher.build_chunk` or `ring()`:

1. **Inversion Detection on Inner Boundary**:
   Let ring $i$ be at arc length $s_i$ and ring $i+1$ at $s_{i+1}$.
   Let $\mathbf{t}_i$ be the centerline tangent at $s_i$.
   For each lateral offset $u$:
   Let $\mathbf{v}_i(u) = \mathbf{p}_i + u \mathbf{n}_i$ and $\mathbf{v}_{i+1}(u) = \mathbf{p}_{i+1} + u \mathbf{n}_{i+1}$.
   Compute the longitudinal edge step:
   $$\delta_{\parallel}(u) = (\mathbf{v}_{i+1}(u) - \mathbf{v}_i(u)) \cdot \mathbf{t}_i$$
   - If $\delta_{\parallel}(u) > 0$: The edge advances forward. Normal quad triangulation $[(i, u), (i+1, u), (i+1, u+1), (i, u+1)]$ is generated.
   - If $\delta_{\parallel}(u) \le 0$: **Swallowtail Singularity Detected!**

2. **Mitre Apex Clamping**:
   When $\delta_{\parallel}(u) \le 0$:
   - The inner edge curve has inverted.
   - Compute the intersection of the two normal rays:
     $$\mathbf{L}_i = \mathbf{p}_i + \lambda \mathbf{n}_i, \quad \mathbf{L}_{i+1} = \mathbf{p}_{i+1} + \mu \mathbf{n}_{i+1}$$
   - The intersection point $\mathbf{p}_{\text{apex}}$ represents the center of curvature apex.
   - Clamp the inner vertex $\mathbf{v}_{i+1}(u)$ to $\mathbf{p}_{\text{apex}}$.
   - Degenerate quad triangles (triangles whose signed area $< 10^{-6}$ or whose normal inverts) are suppressed from the index buffer.
   - **Result**: The inner corner is cleanly mitred into a single sharp vertex. Zero triangles cross over, zero quad rings overlap, and **Z-fighting is completely eliminated**.

---

## 5. Implementation Architecture & File Changes

### 5.1 Modified Files & Responsibilities

| File Path | Subsystem | Planned Changes |
| :--- | :--- | :--- |
| `project/addons/pasture_3d/roads/pasture3d_road_brush.gd` | Issue 1, 3 | Restrict bounds to `_spline_footprint_aabb.intersection(_clip_aabb)`; sub-span ground sampling $[s_{\min}, s_{\max}]$; preserve whole-spline stamp cache during clipped bakes; add `detect_sharp_corners()` and `smooth_sharp_corners()`. |
| `project/addons/pasture_3d/roads/pasture3d_road_network.gd` | Issue 1, 2 | Replace `composite_regions()` with `composite_area(dirty_box, true)`; support per-arm trim updates. |
| `project/addons/pasture_3d/roads/pasture3d_road_chunk_host.gd` | Issue 1, 2 | Add dirty-AABB chunk rebuild filter; pass per-arm cut-face parameters to apron rebuild. |
| `project/addons/pasture_3d/roads/pasture3d_road_junction_solver.gd` | Issue 2 | Decouple per-arm trims from per-road trims; apply mitred crossing trim cap ($2.5 \cdot w_{\text{arm}}$); clamp fillet allowance $A \le \text{TRIM\_CAP}$. |
| `project/addons/pasture_3d/roads/pasture3d_road_junction.gd` | Issue 2 | Store per-arm trims `arm_trims`; provide `footprint_arms()` with per-arm trim values. |
| `project/addons/pasture_3d/roads/pasture3d_road_mesher.gd` | Issue 2, 3 | Remove destructive `convex_hull` fallback; enforce cut-face invariant; implement mitred corner fillet fallback; implement boundary-conforming patch meshing; implement swallowtail clipping in `build_chunk`. |
| `src/pasture_3d_road_mesh.cpp` & `.h` | Issue 3 | Implement C++ SIMD-accelerated swallowtail clipping and mitre clamping in `road_mesh_build_chunk`. |
| `src/pasture_3d_brush_raster.cpp` | Issue 1 | Ensure `stamp_road_line` accepts quantized local sub-grids cleanly when clipped. |

---

## 6. Headless Verification Gates & Acceptance Criteria (`project/bench/`)

All verification gates must execute headlessly (`--headless`), complete in $< 5.0\text{ seconds}$, use active negative controls, and conclude with `get_tree().quit(0 if _fail == 0 else 1)`.

### 6.1 Gate 1: `RoadDirtyRectGate` (`project/bench/RoadDirtyRectGate.gd`, `.tscn`)
- **Criterion A (Dirty-Rect Grid Allocation)**:
  Assert that moving one control point on a $2\text{ km}$ road allocates a sub-grid of size $\le 40 \times 40$ cells, rather than $2000 \times 2000$ cells.
  *Negative Control*: Verify that an unclipped full bake correctly allocates the full $2000 \times 2000$ grid.
- **Criterion B (Sub-Span Alignment & Ground Queries)**:
  Assert that `get_height_below_along_plan` is queried only over the localized arc-length range $[s_{\min}, s_{\max}]$, and that sample count $N_{\text{dirty}} \ll N_{\text{total}}$.
- **Criterion C (Stamp Cache Preservation)**:
  Assert that after a clipped bake, `_stamp_cache` retains the full spline entry with updated values inside the dirty box and uncorrupted values outside.
- **Criterion D (Scoped GPU Composition)**:
  Assert that `composite_area(clip_box)` is called rather than `composite_regions()`, and that untouched terrain regions remain unflagged for GPU texture upload.

### 6.2 Gate 2: `RoadComplexJunctionGate` (`project/bench/RoadComplexJunctionGate.gd`, `.tscn`)
- **Criterion A (Cut-Face Exact Alignment Invariant)**:
  Assert for a 3-road (5-arm) junction and a $15^\circ$ acute crossing that *every* approach cut-face vertex $[a_{\text{cw}}, a_{\text{center}}, a_{\text{ccw}}]$ exists identically in the junction apron mesh (coordinate distance $\le 10^{-4}\text{ m}$).
  *Negative Control*: Perturb a cut-face vertex by $5\text{ mm}$ and assert that seam discrepancy is detected and fails.
- **Criterion B (Zero Boundary Tearing & Convex-Hull Elimination)**:
  Assert that `_is_simple(out)` holds or the mitred corner algorithm prevents self-intersection, and assert that no cut-face center vertex is discarded.
- **Criterion C (Bounded Acute Trim Allowance)**:
  Assert that at a $15^\circ$ crossing, arm trim-back does not exceed $2.5 \times w_{\text{arm}}$, and opposite arms on through-roads are not trimmed back.
- **Criterion D (Watertight C¹ Coons Surface)**:
  Sample elevations across the junction seam at $0.05\text{ m}$ intervals; assert vertical step $\Delta z \le 10^{-4}\text{ m}$ and normal difference $\Delta \mathbf{n} \le 10^{-3}$.

### 6.3 Gate 3: `RoadSharpCornerSmoothingGate` (`project/bench/RoadSharpCornerSmoothingGate.gd`, `.tscn`)
- **Criterion A (Curvature Detection & Radius Assertion)**:
  Generate a sharp $90^\circ$ elbow with $R = 2.0\text{ m}$ on a road with $w_{\text{half}} = 4.0\text{ m}$. Assert that `detect_sharp_corners()` flags the corner with radius $R \approx 2.0\text{ m}$ and severity $> 0$.
- **Criterion B (Spline Smoothing Relaxation)**:
  Execute `smooth_sharp_corners()` on the elbow; assert that post-smoothing radius satisfies $R \ge 1.2 \cdot w_{\text{half}} = 4.8\text{ m}$.
- **Criterion C (Mesher Swallowtail Overlap Elimination)**:
  Pass an un-smoothed sharp turn ($R = 1.5\text{ m} < w_{\text{half}}$) directly to `build_chunk`.
  Assert that:
  1. No quad has inverted winding ($\mathbf{n} \cdot \mathbf{UP} > 0$ everywhere).
  2. No two triangles in the ribbon mesh intersect or overlap in 2D XZ footprint.
  3. Longitudinal inner edge steps satisfy $\delta_{\parallel} \ge 0.0$.
  *Negative Control*: Disable swallowtail clipping in the mesher and assert that inverted quads and self-intersections are detected and fail.

---

## 7. Implementation Plan & Staging

1. **Stage 1 (Issue 1: Localized Spline Edit)**:
   - Update `Pasture3DRoadBrush` bounding box logic and sub-span ground query.
   - Update stamp cache sub-block update logic.
   - Update `Pasture3DRoadNetwork` to call `composite_area` on dirty rects.
   - Build and verify `RoadDirtyRectGate`.

2. **Stage 2 (Issue 2: Complex & Acute Junctions)**:
   - Decouple per-arm trims and implement mitre trim cap in `Pasture3DRoadJunctionSolver`.
   - Implement cut-face preservation and mitred corner return algorithm in `Pasture3DRoadMesher`.
   - Implement boundary-conforming constrained triangulation in `build_coons_patch`.
   - Build and verify `RoadComplexJunctionGate`.

3. **Stage 3 (Issue 3: Sharp Corner Smoothing & Overlap Elimination)**:
   - Implement `detect_sharp_corners` and `smooth_sharp_corners` in `Pasture3DRoadBrush` / `Pasture3DRoadAlignmentSolver`.
   - Implement swallowtail clipping and apex mitring in `Pasture3DRoadMesher` and `src/pasture_3d_road_mesh.cpp`.
   - Build and verify `RoadSharpCornerSmoothingGate`.
   - Register all gates in `project/bench/gates.txt`.
