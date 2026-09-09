# Pasture3D Road — Automatic End-to-End Road Connections & Junction Remediation (P10)

**Document:** `PASTURE3D_ROAD_END_CONNECTION_SPEC.md`  
**Status:** **PROPOSED / SPECIFICATION**  
**Phase:** **P10** (End-to-End Road Connections & Topology Remediation)  
**Builds on:** `PASTURE3D_ROAD_SYSTEM_PROPOSAL.md` §6, `PASTURE3D_ROAD_JUNCTION_PAINT_AND_SMOOTHING_SPEC.md` (P9a/P9b)  
**Key Files Affected:**
- `project/addons/pasture_3d/roads/pasture3d_road_junction.gd`
- `project/addons/pasture_3d/roads/pasture3d_road_junction_solver.gd`
- `project/addons/pasture_3d/roads/pasture3d_road_network.gd`
- `project/addons/pasture_3d/roads/pasture3d_road_mesher.gd`
- `project/addons/pasture_3d/roads/pasture3d_road_lane_solver.gd`
- `project/addons/pasture_3d/roads/pasture3d_road_junction_markings.gd`
- `project/addons/pasture_3d/roads/pasture3d_road_brush.gd`
- `project/bench/RoadEndConnectionGate.gd`

---

## 1. Problem Statement & Motivation

### 1.1 The Missing Capability: Touching Road Ends Do Not Connect
In the current system, junctions are treated exclusively as **crossings** where two roads cross each other in an XZ-planar intersection. When an author places two road splines such that an endpoint of Road A ($s = \text{total}_A$) meets or snaps to an endpoint of Road B ($s = 0$), **nothing happens**:
1. **No Segment Crossing Detected**: [`Pasture3DRoadJunctionSolver.find_crossings`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_junction_solver.gd#L60-L102) uses `_segment_crossing`, which only finds interior segment intersections ($t, u \in (0, 1)$ or exact float equality). Two touching endpoints that meet with a tiny gap ($\le 1.0\text{ m}$) or meet collinearly are discarded.
2. **The Trim-Back Formula Explodes**: The crossing trim-back formula:
   $$\text{trim}_A = \frac{w_B}{\sin \theta}$$
   diverges to $\infty$ as the angle between the roads $\theta \to 0^\circ$ or $180^\circ$. For two roads meeting head-on or along the same line, $\sin \theta \approx 0$, which causes the solver to either clamp to `MIN_CROSSING_ANGLE` ($\sim 7^\circ$) and produce absurd trim-backs ($>30\text{ m}$), or drop the crossing entirely.
3. **Control & Marking Mismatch**: Crossings default to `PRIORITY` or `SIGNALS` with stop bars and give-way markings. Two road ends connecting continuously along a highway or transitioning from 4 lanes to 2 lanes must not tell the driver to stop at the seam.
4. **Lane Graph & Route Severance**: Because no junction is formed, the lane graph remains disconnected. A [`Pasture3DRoadRoute`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_route.gd) stage cannot traverse across the boundary, and traffic agents cannot drive from Road A to Road B.

### 1.2 Junction Remediation (Action Items from Review)
In addition to end-to-end connections, two structural defects discovered during the code review must be resolved:
1. **Phantom Arms at Terminating Roads in `_arms_for`**:
   In [`Pasture3DRoadNetwork._arms_for`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_network.gd#L484-L497), the loop unconditionally iterates over `[BEFORE, AFTER]`. Because `Pasture3DRoadAlignment.height_at` clamps out-of-bounds arc lengths rather than returning `NAN`, every T-junction road generates a phantom second arm pointing East (`Vector2.RIGHT`), corrupting lane connector curves and markings.
2. **Synthetic 90° Fallback in Clustered Trim Calculations**:
   In [`Pasture3DRoadJunctionSolver._angle_between`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_junction_solver.gd#L487-L495), if two roads in a cluster do not cross directly, the angle is hardcoded to $\frac{\pi}{2}$ ($90^\circ$). Acute merging/diverging arms severely under-trim, causing approaching ribbons to collide.

---

## 2. Geometric & Mathematical Specification

### 2.1 Endpoint Proximity Detection (`find_endpoint_connections`)
In [`Pasture3DRoadJunctionSolver`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_junction_solver.gd), alongside `find_crossings`, evaluate all road endpoint pairs:
- Terminals for road $i$:
  - Start: $s = 0.0$, position $\mathbf{p}_{i,0} = \text{plan}_i[0]$, tangent $\mathbf{t}_{i,0} = \text{tangent\_at}(0)$
  - End: $s = \text{total}_i$, position $\mathbf{p}_{i,1} = \text{plan}_i[-1]$, tangent $\mathbf{t}_{i,1} = \text{tangent\_at}(\text{total}_i)$
- A connection candidate exists between terminal $(i, \text{end}_A)$ and $(j, \text{end}_B)$ ($i \neq j$) if:
  $$\|\mathbf{p}_A - \mathbf{p}_B\| \le \epsilon_{\text{endpoint}} \quad (\text{default } 1.5\text{ m})$$
  $$\text{and } |z_A - z_B| \le \text{clearance} \quad (\text{default } 5.5\text{ m})$$
  $$\text{and neither terminal is flagged as on a bridge}$$

The meeting point $\mathbf{p}_{\text{meet}}$ is snapped to:
- If priorities differ: the endpoint of the higher-priority road.
- If priorities tie: the midpoint $\frac{1}{2}(\mathbf{p}_A + \mathbf{p}_B)$.

### 2.2 Junction Classification: `CROSSING` vs. `END_TO_END`
In [`Pasture3DRoadJunction`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_junction.gd), introduce `JunctionKind`:
```gdscript
enum JunctionKind { CROSSING = 0, END_TO_END = 1 }
@export var kind: JunctionKind = JunctionKind.CROSSING
```
A junction is classified as `END_TO_END` when:
1. It has exactly two participating arms ($\text{arm\_count} = 2$).
2. Both arms terminate at the junction: $s_i \le \text{ARM\_MIN\_LENGTH}$ or $\text{total}_i - s_i \le \text{ARM\_MIN\_LENGTH}$.
3. The angle between the two arm directions indicates a sequential continuation ($\phi \in [0, \pi - \epsilon_{\text{turn}}]$ where $\mathbf{d}_A \cdot \mathbf{d}_B < 0$ for straight continuation).

### 2.3 Closed-Form Trim-Back for End-to-End Connections
For an `END_TO_END` junction between Road A and Road B:
Let $\phi$ be the deflection angle between the two road directions:
$$\phi = \arccos(\text{clamp}(\mathbf{t}_A \cdot \mathbf{t}_B, -1.0, 1.0))$$

Three geometric cases govern the trim:

```
Case 1: Collinear / Straight (phi < 7°)
  Road A ===================|=================== Road B
                         trim = 0
  (Ribbons meet flush at cut face, zero gap)

Case 2: Lane/Width Transition (wA != wB, phi < 7°)
  Road A ===================\
                             \================= Road B
  (Trapezoidal transition apron bridges the width step)

Case 3: Corner / Angled Bend (phi >= 7°)
             / Road B
            / 
           / ) phi
  Road A ==+
  (Trim governed by fillet allowance: trim = R / tan(phi/2))
```

1. **Collinear Continuation ($\phi < \text{MIN\_CROSSING\_ANGLE}$)**:
   - If widths match ($w_A = w_B$): $\text{trim}_A = 0.0$, $\text{trim}_B = 0.0$.
   - The two ribbons meet flush at the cut face.
   - If widths differ ($w_A \neq w_B$): $\text{trim}_A = \text{trim}_B = \frac{1}{2} L_{\text{taper}}$ where $L_{\text{taper}} = |w_A - w_B| \times 3.0$ (or a minimum $2.0\text{ m}$ transition length).
2. **Angled Bend / Corner ($\phi \ge \text{MIN\_CROSSING\_ANGLE}$)**:
   - Trim is determined strictly by the corner fillet radius $R$:
     $$\text{trim}_A = \text{trim}_B = \frac{R}{\tan(\phi / 2)}$$
   - The diverging formula $w / \sin \theta$ is **completely bypassed**.

### 2.4 Transition Footprint Polygon & Boundary Heights
In [`Pasture3DRoadMesher.plan_footprint`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_mesher.gd):
- For `END_TO_END` connections:
  - If $\text{trim} == 0.0$: emit a 4-vertex quad joining the two cut faces directly:
    $[A_{\text{left}}, A_{\text{right}}, B_{\text{left}}, B_{\text{right}}]$.
  - If widths differ: emit a trapezoidal quad connecting the 3 cut-face vertices of Road A ($[-w_A, 0, w_A]$) to the 3 cut-face vertices of Road B ($[-w_B, 0, w_B]$).
  - If angled: emit the two cut faces plus the inner fillet arc and the outer miter corner.
- **Boundary Heights**:
  - Sampled directly from each road's cut face cross-section ($z, \text{bank}, \text{crown}$).
  - Interpolated across the transition trapezoid so height, crown, and camber smoothly blend from Road A to Road B.

### 2.5 Elevation & Gradient Continuity
In [`Pasture3DRoadJunctionSolver._resolve_group`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_junction_solver.gd):
- The higher-priority road determines `elevation`.
- The lower-priority road is pinned to `elevation` at its endpoint.
- **Gradient Continuity**: In addition to height $z$, pass the arrival slope $\frac{dz}{ds}$ from Road A as a gradient hint/pin to Road B's vertical solve, preventing an abrupt vertical kink at the seam.

### 2.6 Lane Graph & Connectivity (`Pasture3DRoadLaneSolver`)
For an `END_TO_END` junction:
1. **Direct Ordinal Pairing**:
   - Forward incoming lanes of Road A connect 1-to-1 to forward outgoing lanes of Road B.
   - Backward incoming lanes of Road B connect 1-to-1 to backward outgoing lanes of Road A.
2. **Lane Count Mismatches (Merging/Tapering)**:
   - If Road A has 4 lanes and Road B has 2 lanes:
     - The inside lanes pair directly.
     - The outside lane tapers and merges into the adjacent lane following the world's `traffic_side` rule.
3. **Default Control**:
   - `control` defaults to `ControlType.UNCONTROLLED`.
   - All turns classify as `Turn.STRAIGHT` (or gentle `LEFT`/`RIGHT` for bends).
   - Stop bars, crosswalks, and give-way markings are **suppressed**.

---

## 3. Junction Remediation Specification

### 3.1 Fix Phantom Arms in `Pasture3DRoadNetwork._arms_for`
**Root Cause:**
`_arms_for` iterates over `[BEFORE, AFTER]` without checking if the road actually extends past the junction. Because `Pasture3DRoadAlignment.height_at` clamps out-of-range queries, `is_finite(y)` always passes, creating a phantom arm pointing in a fallback direction.

**Correction:**
In [`pasture3d_road_network.gd:L484-L498`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_network.gd#L484-L498):
```gdscript
var total: float = brush.total_arc_length()
for end in [Pasture3DRoadLaneConnector.End.BEFORE, Pasture3DRoadLaneConnector.End.AFTER]:
    # A road ending at or near the junction has no AFTER arm:
    if end == Pasture3DRoadLaneConnector.End.AFTER and total - s <= Pasture3DRoadJunctionSolver.ARM_MIN_LENGTH:
        continue
    # A road starting at or near the junction has no BEFORE arm:
    if end == Pasture3DRoadLaneConnector.End.BEFORE and s <= Pasture3DRoadJunctionSolver.ARM_MIN_LENGTH:
        continue
    var at: float = s - trim if end == Pasture3DRoadLaneConnector.End.BEFORE else s + trim
    ...
```

### 3.2 Robust Angle Calculation in `Pasture3DRoadJunctionSolver._angle_between`
**Root Cause:**
In clustered junctions, non-directly intersecting pairs fall back to $\frac{\pi}{2}$ ($90^\circ$), causing severe under-trimming on acute slip roads.

**Correction:**
In [`pasture3d_road_junction_solver.gd:L487-L495`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_junction_solver.gd#L487-L495):
```gdscript
static func _angle_between(p_crossings: Array, p_group: Array, p_i: int, p_j: int,
        p_runs: Array = [], p_arcs: Array = []) -> float:
    for ci: int in p_group:
        var c: Dictionary = p_crossings[ci]
        if (c["a"] == p_i and c["b"] == p_j) or (c["a"] == p_j and c["b"] == p_i):
            return float(c["angle"])
    # Fallback to tangent dot-product at the junction arc lengths:
    if p_i < p_runs.size() and p_j < p_runs.size() and p_i < p_arcs.size() and p_j < p_arcs.size():
        var da := _tangent_at(p_runs[p_i], float(p_arcs[p_i]))
        var db := _tangent_at(p_runs[p_j], float(p_arcs[p_j]))
        if da.length_squared() > 0.5 and db.length_squared() > 0.5:
            return acos(clampf(absf(da.dot(db)), 0.0, 1.0))
    return PI * 0.5
```

---

## 4. Test & Verification Plan (`RoadEndConnectionGate`)

Create `project/bench/RoadEndConnectionGate.gd` covering the following assertions and mutation controls:

| # | Criterion | Expected Result | Control / Mutation That Must Fail |
|---|---|---|---|
| **A** | Two collinear roads with endpoints within $1.0\text{ m}$ form an `END_TO_END` junction. | Exactly 1 junction, `kind == END_TO_END`, 2 arms. | Move roads $5.0\text{ m}$ apart $\to$ 0 junctions found. |
| **B** | Trim-back on collinear matching roads is $\le 1e-3\text{ m}$. | Both trims equal $0.0\text{ m}$. | Force crossing formula $w / \sin \theta \to$ trim exceeds $30\text{ m}$. |
| **C** | Lane solver connects incoming lanes 1-to-1 without stop lines. | Legal connectors generated, 0 stop lines, 0 give-way triangles. | Treat as crossing $\to$ stop lines emitted on incoming arm. |
| **D** | T-junction road emits exactly 1 arm in `_arms_for`. | Terminating road contributes 1 arm, not 2. | Remove arc-length range guard $\to$ 2 arms emitted with phantom tangent. |
| **E** | Clustered indirect acute pair uses tangent angle, not $90^\circ$. | Angle evaluates to $\sim 15^\circ$, trim $> 15\text{ m}$. | Revert to $90^\circ$ fallback $\to$ trim collapses to $4\text{ m}$. |
| **F** | Lane count transition (4-lane to 2-lane) generates tapering connector curves. | Connectors taper ordinal lanes, boundary forms trapezoid. | Fix boundary as rectangle $\to$ corner vertices miss cut faces. |
| **G** | Route traversal across end-to-end connection is continuous. | `Pasture3DRoadRoute.sample()` crosses the seam with $C^0$ height and smooth tangent. | Disconnect junction $\to$ route fails to traverse beyond Road A. |

---

## 5. Implementation Sequence

1. **Step 1: Fix Core Remediation Bugs**
   - Patch `_arms_for` in `pasture3d_road_network.gd`.
   - Patch `_angle_between` in `pasture3d_road_junction_solver.gd`.
2. **Step 2: Endpoint Proximity Detection & Classification**
   - Add `JunctionKind` to `pasture3d_road_junction.gd`.
   - Add endpoint connection finding to `pasture3d_road_junction_solver.gd`.
3. **Step 3: End-to-End Trim & Mesh Handling**
   - Update `_resolve_group` to apply zero/taper/fillet trim for end-to-end junctions.
   - Update `Pasture3DRoadMesher.plan_footprint` to build transition quads/trapezoids.
4. **Step 4: Lane Topology & Marking Suppression**
   - Update `Pasture3DRoadLaneSolver` to generate direct 1-to-1 connectors and suppress stop lines on end-to-end joins.
   - Update `Pasture3DRoadJunctionMarkings` to suppress crossing markings.
5. **Step 5: Gate Testing**
   - Implement `RoadEndConnectionGate.gd` and verify that all criteria and mutation controls pass cleanly.
