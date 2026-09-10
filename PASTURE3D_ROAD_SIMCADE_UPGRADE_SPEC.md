# Pasture3D Road System — High-Speed Simcade & Racing Physics Specification

**Document Version:** 1.0  
**Target Engine:** Godot 4.7+ / GDExtension (C++ / GDScript)  
**Status:** SPECIFICATION READY FOR IMPLEMENTATION  
**Builds on:** `PASTURE3D_ROAD_SYSTEM_PROPOSAL.md`, `PASTURE3D_ROAD_JUNCTION_PAINT_AND_SMOOTHING_SPEC.md`, `PASTURE3D_ROAD_BRUSH_PERF_SPEC.md`  

---

## 1. Executive Summary & Problem Statement

Pasture3D's existing road system (Phases P0–P7) provides civil-engineering vertical alignment solving, earthwork cut/fill grading, control-map paint, and pace-note generation tailored for point-to-point terrain dressing. However, its current surface generation architecture has five critical deficiencies when subjected to high-speed simcade racing vehicle dynamics (120–300+ km/h):

1. **Driving Collision on Grid Heightmaps**: The driving surface relies primarily on the terrain heightmap (`collision_enabled = false` by default; ribbon collider intended only as an "identity" raycast mask). A vehicle traveling diagonally across a 1.0m heightmap grid experiences severe normal aliasing, polygon chatter, and tyre slip angle instability. Furthermore, bridges and overpasses have no terrain under the road deck, causing vehicles to fall through without manual collision workarounds.
2. **The 2cm Visual Disconnect (`DEPTH_LIFT`)**: The visual ribbon is offset $+0.02\text{ m}$ (2 cm) above the terrain to prevent Z-fighting. Vehicles driving on the terrain heightfield have their tyres visually sunken 2 cm into the asphalt.
3. **Knife-Edge $V$-Shaped Crown**: The cross-section height is computed as $\text{centre} + \text{bank}\cdot u - \text{crown}\cdot |u|$. The absolute-value term $|u|$ introduces a $C^0$ derivative discontinuity along the exact centerline, producing a knife-edge crease that destabilizes cars during lane-crossing and overtakes. Moreover, additive crown inside banked corners produces an unnatural ridge in banked bowls.
4. **Absence of Procedural Racing Kerbs & Rumble Strips**: Cross-sections are hardcoded to a 5-vertex flat ribbon (`[-(half + shoulder), -half, 0, half, half + shoulder]`). There is no support for procedural apex/exit rumble kerbs, bevels, or drainage gutters.
5. **Piecewise-Linear Discretization & Radial Fan Junctions**: Centerlines are tessellated into piecewise-linear segments via `Curve3D.tessellate()`, causing lateral jerk spikes ($d^3x/dt^3$) on corner entry. Junction aprons are meshed as radial triangle fans converging on a single center vertex, generating spoke ridges that upset suspension during diagonal crossings.

This specification details the end-to-end upgrade required to turn Pasture3D into a **competition-grade simcade racing road engine**.

---

## 2. Core Architectural Decisions (Aligned via Design Review)

| Subsystem | Upgraded Architectural Standard |
| :--- | :--- |
| **Driving Surface** | **Hybrid Authoritative 3D Ribbon**: Ribbon mesh collider is the primary driving surface for paved roads (at `lift = 0.0`, coplanar with visuals), seamlessly meeting terrain heightmap collision on the verges. Bridges/tunnels carry full 3D collision. Unpaved trails/off-road sections can disable the ribbon and fall back to heightfield. |
| **Road Terminus** | **Bevelled Pavement Apron End-Cap**: Extruded asphalt transition lip with a rounded bevel edge and gentle slope leading down onto the dirt terrain. |
| **Kerbs & Edges** | **Parametric Kerb System**: Built-in presets (FIA Bevel, Sawtooth Rumble, Flat Slab, Negative Gutter) configured on `Pasture3DRoadType`, selectively placed/suppressed per side on `Pasture3DRoadSegment` (apex/exit kerbs). |
| **Crown & Camber** | **Multi-Mode Parabolic Crown with Superelevation Runoff**: Smooth quadratic curve ($y = -c\cdot u^2$) with no centerline crease, One-Way Cross-Fall for dual carriageways/ovals, and automatic adverse crown attenuation as banking increases. |
| **Plan Splines** | **Dense Arc-Length Resampling with $C^2$ Curvature Smoothing**: Uniform 0.5m stepping, continuous analytic tangents, and transition spiral smoothing to eliminate lateral jerk spikes on corner entry/exit. |
| **Vertical Alignment** | **Velocity-Aware Vertical Acceleration Limiter**: Hard bounds on vertical curvature $|d^2z/ds^2| \le a_{\text{max}} / v^2$ based on design speed to prevent cars bottoming out in sags or unintentionally jumping crests, with an explicit `is_jump` flag for rally brows. |
| **Junction Driving Surface** | **Bivariate Coons Surface Patch**: Blended mathematical surface patch eliminating radial center-fan spoke ridges and smoothly bridging multi-arm cross-falls and grades. |
| **Surface Physics** | **Dual `PhysicsMaterial` + Collider Telemetry**: Real Godot `PhysicsMaterials` assigned to chunk `StaticBody3D` colliders, supplemented by `Pasture3DSurfaceInfo` metadata for instant tyre raycast/shapecast telemetry (grip $\mu$, micro-roughness, audio/VFX tags). |
| **Route Topologies** | **Full Dual Topology (Rally Stages + Closed Circuits)**: `Pasture3DRoadRoute` supports both point-to-point stages and closed circuits with lap counts, sector split gates, lap-wrap progress tracking, and seamless loop seam closure. |
| **Implementation Backend** | **C++ GDExtension with GDScript Parity Oracles**: Core performance-critical math implemented in C++ (`src/pasture_3d_road_grade.cpp`, `src/pasture_3d_util.cpp`) with GDScript reference oracles and bench gates under `project/bench/`. |

---

## 3. Detailed Technical Specification

### 3.1 Authoritative 3D Ribbon Driving Collision & Rendering Pipeline

#### 3.1.1 Elimination of the Visual vs. Physical Height Discrepancy
- In the current code, `Pasture3DRoadMesher.DEPTH_LIFT = 0.02` lifts the visual ribbon 2 cm above the ground, while `_add_collider` generates collision at lift `0.0`.
- Under the upgraded architecture:
  1. The **Driving Ribbon Collider** is built at `lift = 0.0`.
  2. The **Rendered Ribbon Mesh** is also generated at `lift = 0.0`.
  3. To prevent Z-fighting between the ribbon mesh and the underlying graded terrain without introducing a physical height gap, Pasture3D will employ a **Depth Bias / Polygon Offset in the road shader** (`render_mode depth_draw_always, depth_test_disabled` or Vulkan depth bias `depth_bias_constant = -2.0, depth_bias_slope_scale = -1.5`) rather than geometric vertex elevation.
  4. Where terrain grading is performed, the terrain under the carriageway is stamped with a hole/mask or lowered by an epsilon beneath the ribbon, ensuring zero Z-fighting and bit-identical wheel contact and rendering heights.

#### 3.1.2 Surface Mode Configuration on `Pasture3DRoadType`
Add an enum property to `Pasture3DRoadType`:
```gdscript
enum SurfaceMode {
    RIBBON_PHYSICS,  ## Paved road / race track: authoritative 3D ribbon collider + visual mesh.
    TERRAIN_DRAPED,  ## Dirt trail / footpath: no ribbon mesh; terrain heightmap is the driving surface.
}
@export var surface_mode: SurfaceMode = SurfaceMode.RIBBON_PHYSICS
```
When `surface_mode == SurfaceMode.TERRAIN_DRAPED`:
- No ribbon mesh or ribbon collider is built.
- The road is purely graded and painted into the terrain control map.
- The car drives directly on the terrain heightfield.

When `surface_mode == SurfaceMode.RIBBON_PHYSICS`:
- Full 3D chunked ribbon colliders (`ConcavePolygonShape3D` on `collision_layer = 1 | 2`) are generated for all spans.
- On bridges and elevated viaducts (`is_bridge == true`), the ribbon collider is generated unconditionally even though terrain grading is suppressed.

---

### 3.2 Bevelled Pavement Terminal Aprons (Road End Transitions)

When a paved road (`RIBBON_PHYSICS`) transitions to an unpaved trail or terminates into bare terrain, it must not end with an abrupt, razor-sharp polygon edge.

```
       Paved Ribbon Surface (z_road)
═════════════════════════════════════════\
                                          \  <- Bevel Lip (15-30 cm radius)
                                           \
                                            \________  Transition Ramp (1.5 - 3.0 m)
                                                     \
──────────────────────────────────────────────────────════════  Terrain Ground
```

#### Geometry Specification:
1. **End-Cap Detection**: A terminus occurs at $s = 0$ or $s = s_{\text{total}}$ when the brush has no adjacent junction, or at a segment boundary where `surface_mode` switches from `RIBBON_PHYSICS` to `TERRAIN_DRAPED`.
2. **Bevel Profile**:
   - `apron_length`: Length of the transition ramp (default $2.5\text{ m}$).
   - `apron_drop`: Depth to which the lip bevels down into the terrain (default $0.08\text{ m}$).
   - `apron_roundness`: Fillet radius along the lateral edge corners.
3. **Mesh & Collision Generation**:
   - The mesher extrudes 3–4 additional rings beyond the road end, curving downward smoothly via a Hermite cubic curve from $(s_{\text{end}}, z_{\text{road}}, \mathbf{t}_{\text{road}})$ to $(s_{\text{end}} + L_{\text{apron}}, z_{\text{ground}}, \mathbf{t}_{\text{ground}})$.
   - Both visual mesh and collision shape include this bevelled ramp, guaranteeing that a vehicle transitioning off the tarmac rolls smoothly down onto the dirt without catching an inverted collision triangle edge.

---

### 3.3 Parametric Racing Kerbs & Extruded Edge Profiles

#### 3.3.1 Kerb Profiles on `Pasture3DRoadType`
Add kerb configuration to `Pasture3DRoadType`:
```gdscript
enum KerbType {
    NONE,           ## Standard flush asphalt shoulder
    FIA_BEVEL,      ## Smooth 45° chamfered concrete kerb (5-10 cm height)
    SAWTOOTH,       ## Aggressive rumble strip with periodic sawtooth displacement
    FLAT_SLAB,      ## Flat concrete boundary slab (flush with asphalt, textured)
    DRAIN_GUTTER,   ## Negative depression / parabolic concave gutter for water runoff
}

@export_group("Kerbs & Shoulders")
@export var default_left_kerb: KerbType = KerbType.NONE
@export var default_right_kerb: KerbType = KerbType.NONE
@export var kerb_width: float = 0.8          ## Width in metres beyond carriageway
@export var kerb_height: float = 0.08        ## Height above road surface in metres
@export var kerb_rumble_pitch: float = 0.4   ## Longitudinal wavelength of sawtooth rumble in metres
@export var kerb_rumble_depth: float = 0.02  ## Amplitude of physical vibration displacement
```

#### 3.3.2 Per-Segment Kerb Placement on `Pasture3DRoadSegment`
A racetrack designer authors apex and exit kerbs over specific arc-length intervals:
```gdscript
@export var left_kerb: KerbType = KerbType.NONE
@export var right_kerb: KerbType = KerbType.NONE
```
If set to a value other than `NONE`, the segment overrides the road type's default over its `[from_distance, to_distance]` span.

#### 3.3.3 Kerb Cross-Section Vertex Math
When a kerb is present on side $k \in \{-1, +1\}$ (left/right), the mesher replaces the single shoulder vertex with a 4-vertex kerb cross-section:
1. **Inner Edge**: At $u = k \cdot w_{\text{half}}$, height $= z_{\text{road}}(u)$.
2. **Kerb Lip (Rumble)**: At $u = k \cdot (w_{\text{half}} + 0.1\text{ m})$, height $= z_{\text{road}}(u) + h_{\text{kerb}} + \delta_{\text{rumble}}(s)$.
3. **Kerb Crown / Flat**: At $u = k \cdot (w_{\text{half}} + w_{\text{kerb}} - 0.1\text{ m})$, height $= z_{\text{road}}(u) + h_{\text{kerb}} + \delta_{\text{rumble}}(s)$.
4. **Outer Batter Toe**: At $u = k \cdot (w_{\text{half}} + w_{\text{kerb}})$, sloping back down to meet the verge/ground.

Where the physical rumble displacement $\delta_{\text{rumble}}(s)$ for `SAWTOOTH` is:
$$\delta_{\text{rumble}}(s) = A_{\text{rumble}} \cdot \text{sawtooth}\left(\frac{2\pi s}{\lambda_{\text{rumble}}}\right)$$
This displacement is baked directly into the **LOD 0 visual mesh and LOD 0 collision trimesh**, allowing physical vehicle wheels and physics raycasts to feel genuine rumble vibration and steering wheel FFB without requiring separate collision volumes.

---

### 3.4 Multi-Mode Smooth Parabolic Crown & Superelevation Runoff

#### 3.4.1 Crown Mathematical Models
In `Pasture3DRoadType`, replace the single `crown` float with:
```gdscript
enum CrownMode {
    PARABOLIC,          ## Smooth quadratic crown: y = -c * (u / half_width)^2 (Recommended)
    ONE_WAY_CROSSFALL,  ## Monotonic planar tilt: y = -c * (u / half_width) (Motorways / Ovals)
    CIRCULAR_ARC,       ## Exact circular arc radius
    V_ROOF,             ## Legacy sharp peak
}

@export var crown_mode: CrownMode = CrownMode.PARABOLIC
@export var crown_height: float = 0.05 ## Peak-to-edge drop in metres
```

#### 3.4.2 Parabolic Crown Formulation
For a carriageway with half-width $w_h$:
$$z_{\text{crown}}(u) = - h_{\text{crown}} \cdot \left(\frac{u}{w_h}\right)^2 \quad \text{for } |u| \le w_h$$
- At $u = 0$ (centerline): $z_{\text{crown}}(0) = 0$, and the first derivative is:
  $$\frac{dz_{\text{crown}}}{du}\Big|_{u=0} = -2 h_{\text{crown}} \frac{u}{w_h^2}\Big|_{u=0} = 0$$
  **The slope across the centerline is zero.** There is no knife-edge crease; crossing between lanes is smooth.
- At $u = \pm w_h$ (edges): $z_{\text{crown}}(\pm w_h) = -h_{\text{crown}}$, matching the road's drainage design.

#### 3.4.3 Superelevation Runoff (Adverse Crown Elimination)
When a road enters a curve with banking $\beta = \text{bank}(s)$:
1. A banked road must not retain a crown that slopes against the bank (adverse crown).
2. The effective crown is attenuated dynamically by the curve banking ratio:
   $$\eta(s) = \text{clamp}\left(1.0 - \frac{|\beta(s)|}{\beta_{\text{max}}}, 0.0, 1.0\right)$$
   $$z_{\text{surface}}(u, s) = z_{\text{centre}}(s) + \beta(s) \cdot u + \eta(s) \cdot z_{\text{crown}}(u)$$
3. **Result**:
   - On straights ($\beta = 0$): Full parabolic drainage crown $\eta = 1.0$.
   - In full-speed banked corners ($|\beta| = \beta_{\text{max}}$): Crown smoothly collapses to zero ($\eta = 0.0$), creating a perfect, planar superelevated racing bowl.

---

### 3.5 $C^2$-Continuous Spline Resampling & Curvature Smoothing

#### 3.5.1 The Plan Sampling Problem
Currently, `_plan_points()` takes raw vertices from `path.curve.tessellate()`. On a straight section, control points can be $300\text{ m}$ apart; on curves, they cluster irregularly. 

#### 3.5.2 Upgraded Plan Pipeline
1. **Uniform Arc-Length Pre-Sampling**:
   Instead of `tessellate()`, the brush samples the authored `Path3D.curve` using uniform arc-length sampling at interval $\Delta s_{\text{plan}} = 0.5\text{ m}$:
   $$\mathbf{P}_i = \text{curve.sample\_baked}(i \cdot \Delta s_{\text{plan}})$$
2. **Analytic Tangent & Heading Calculation**:
   Compute unit tangent vectors $\mathbf{T}_i$ via continuous 5-point Savitzky-Golay filtering or analytic curve derivatives:
   $$\mathbf{T}_i = \frac{-\mathbf{P}_{i+2} + 8\mathbf{P}_{i+1} - 8\mathbf{P}_{i-1} + \mathbf{P}_{i-2}}{12 \Delta s_{\text{plan}}}$$
3. **Transition Spiral (Euler / Clothoid) Curvature Smoothing**:
   Calculate curvature $\kappa_i = d\theta / ds$. Apply a transition filter over length $L_{\text{transition}} = \max(25\text{ m}, v_{\text{design}} \cdot 1.5\text{ s})$:
   - On tangent-to-curve transitions, curvature ramps linearly from $0$ to $\kappa_{\text{peak}}$, matching clothoid geometry:
     $$\kappa(s) = \frac{s}{L_{\text{transition}}} \cdot \kappa_{\text{peak}}$$
   - This eliminates instantaneous centrifugal shock: lateral acceleration $a_y = v^2 \kappa(s)$ ramps smoothly, preventing physics suspension snap and steering wheel force-feedback spikes.

---

### 3.6 Velocity-Aware Vertical Acceleration Limiting ($a_z$ & $K$-Values)

#### 3.6.1 The Engineering Equation
In `Pasture3DRoadAlignmentSolver`, the objective function currently penalizes cut/fill and slope variance, constrained only by $|dz/ds| \le g_{\text{max}}$.
For racing vehicles at design speed $v_{\text{design}}$:
- **Crest Vertical Acceleration Limit** (preventing airborne launch / negative G):
  $$\frac{d^2z}{ds^2} \ge -\frac{a_{\text{crest\_max}}}{v_{\text{design}}^2}$$
  Where $a_{\text{crest\_max}}$ defaults to $0.4 g$ ($3.92\text{ m/s}^2$). Above this value, driver sight distance is compromised and vehicles become dangerously unweighted.
- **Sag Vertical Acceleration Limit** (preventing suspension bump-stop bottoming):
  $$\frac{d^2z}{ds^2} \le \frac{a_{\text{sag\_max}}}{v_{\text{design}}^2}$$
  Where $a_{\text{sag\_max}}$ defaults to $0.6 g$ ($5.88\text{ m/s}^2$).

#### 3.6.2 Solver Integration
Add to `Pasture3DRoadAlignmentSolver.solve()`:
1. `max_vertical_curvature_crest = a_crest_max / (v_design * v_design)`
2. `max_vertical_curvature_sag = a_sag_max / (v_design * v_design)`
3. During the alternating projection passes (`_project_grade`), add a second-difference clamping projection on consecutive triples:
   $$\Delta^2 z_i = \frac{z_{i-1} - 2z_i + z_{i+1}}{\Delta s^2}$$
   Clamping $\Delta^2 z_i$ within $[-\kappa_{v,\text{crest}}, \kappa_{v,\text{sag}}]$.
4. **Intentional Brow / Jump Flag**:
   In `Pasture3DRoadSegment`, add `@export var allow_airborne_jump: bool = false`. If true over a segment, the solver bypasses $a_{\text{crest\_max}}$ constraint, allowing rally stage designers to author intentional crest jumps.

---

### 3.7 Bivariate Coons Surface Patch for Intersections

#### 3.7.1 The Radial Fan Problem
Current aprons in [`pasture3d_road_mesher.gd:325-340`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_mesher.gd#L325-L340) connect all perimeter points to `p_center` via a triangle fan. Crossing a 4-way intersection diagonally means rolling over 4 distinct radial spoke creases.

#### 3.7.2 Transfinite Interpolation (Bivariate Coons Patch) Formulation
For an intersection connecting $M$ arms ($M \ge 3$):
1. **Domain Parameterization**: The junction footprint polygon is mapped to a convex planar boundary $\mathbf{B}(t)$.
2. **Boundary Height & Slope Hermite Conditions**: Each arm $k$ imposes position $\mathbf{x}_k(u)$, elevation $z_k(u)$, grade $g_k(u)$, and cross-fall $b_k(u)$ along its cut face.
3. **Interior Surface Evaluation**:
   For any interior point $\mathbf{p} = (x, z)$ inside the footprint:
   $$Z(\mathbf{p}) = \sum_{k=1}^M w_k(\mathbf{p}) \cdot \left[ z_k(\mathbf{p}) + (\mathbf{p} - \mathbf{c}_k) \cdot \nabla z_k \right]$$
   Where $w_k(\mathbf{p})$ is the generalized barycentric coordinate (Wachspress or Mean Value Coordinates) of $\mathbf{p}$ relative to arm $k$.
4. **Grid Triangulation**:
   - The interior is discretized as a regular 2D quad/triangle grid (spacing $\Delta = 1.0\text{ m}$) bounded by the fillet outline, rather than a single center fan.
   - Vertices are evaluated directly from $Z(\mathbf{p})$.
   - **Result**: The intersection forms a mathematically continuous, differentiable 3D surface patch ($C^1$ smooth) with zero radial spoke creases.

---

### 3.8 Surface Physics Telemetry & PhysicsMaterial Integration

#### 3.8.1 `Pasture3DSurfaceInfo` Metadata Resource
Create a new resource class:
```gdscript
class_name Pasture3DSurfaceInfo
extends Resource

@export var surface_id: StringName = &"tarmac"
@export var friction_longitudinal: float = 1.05
@export var friction_lateral: float = 1.00
@export var rolling_resistance: float = 0.015
@export var roughness_amplitude: float = 0.002 ## Micro-bump noise in metres
@export var roughness_frequency: float = 18.0   ## Hz at 100 km/h
@export var audio_surface_type: StringName = &"asphalt"
@export var particle_effect_type: StringName = &"tire_smoke"
```

#### 3.8.2 Attachment to `StaticBody3D`
In [`pasture3d_road_chunk_host.gd:_collider_from()`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_chunk_host.gd#L293-L309):
```gdscript
var body := StaticBody3D.new()
body.name = "Collision"
body.collision_layer = collision_layer
body.collision_mask = collision_mask

# 1. Standard Godot PhysicsMaterial
var pm := PhysicsMaterial.new()
pm.friction = surface_info.friction_longitudinal
pm.bounce = 0.0
body.physics_material_override = pm

# 2. Rich telemetry metadata for vehicle physics raycasts / shapecasts
body.set_meta(&"pasture3d_surface", surface_info)
```
Vehicle physics wheel raycasts (`RayCast3D` or `ShapeCast3D`) can directly read:
```gdscript
if collider.has_meta(&"pasture3d_surface"):
    var info: Pasture3DSurfaceInfo = collider.get_meta(&"pasture3d_surface")
    current_grip = info.friction_longitudinal
```
This bypasses all script lookups during high-frequency physics ticks ($60\text{–}240\text{ Hz}$).

#### 3.8.3 Fast Spatial Query Acceleration in C++
Bind `Pasture3DPathGeom.nearest` into `Pasture3DUtil`:
```cpp
// In src/pasture_3d_util.cpp
Dictionary Pasture3DUtil::path_geom_locate(const Pasture3DPathGeom &geom, const Vector3 &world_pos);
```
In [`pasture3d_road_run.gd:locate()`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_run.gd#L177-L191), replace the brute-force linear loop with the dense CSR uniform grid lookup:
- **Complexity**: Reduced from $O(N)$ linear segment checks to $O(1)$ grid bucket queries.
- **Performance**: 16 AI vehicles querying `locate()` at 60 Hz drops CPU execution time from $\sim 8.4\text{ ms}$ (GDScript) to $< 0.1\text{ ms}$ (C++).

---

### 3.9 Dual-Topology Racing Route System: Stages + Closed Circuits

#### 3.9.1 Topology Enum on `Pasture3DRoadRoute`
In [`pasture3d_road_route.gd`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/roads/pasture3d_road_route.gd):
```gdscript
enum RouteTopology {
    POINT_TO_POINT, ## Rally stage: starts at s=0, ends at s=total, no loop wrapping.
    CLOSED_CIRCUIT, ## Track racing: loop wraps s=total back to s=0 with lap counters.
}

@export var topology: RouteTopology = RouteTopology.POINT_TO_POINT
@export var lap_count: int = 3
@export var sector_gates: PackedFloat32Array = PackedFloat32Array() ## Split timing gates
```

#### 3.9.2 Seam Closure Contract
When `topology == RouteTopology.CLOSED_CIRCUIT`:
1. The last run entry must connect back to the first run entry at a shared junction or coincident position.
2. `progress(world_pos)` automatically handles loop wrap-around:
   $$\text{lap\_index} = \lfloor s_{\text{accum}} / L_{\text{track}} \rfloor$$
   $$s_{\text{lap}} = s_{\text{accum}} \pmod{L_{\text{track}}}$$
3. Start/Finish gate plane is placed at $s = 0$.
4. Sector split gates are evaluated with crossing timestamps for lap split delta telemetry.

---

## 4. Phase Plan, Deliverables & Gate Verification

Following Pasture3D's strict architectural discipline, every new phase delivers a headless test gate under `project/bench/` with numeric verification and active failure controls.

```
P9a: Hybrid Driving Collider & Coplanar Shader Mesh
     └── Gate: RoadDrivingSurfaceGate
P9b: Bevelled Pavement Terminal Apron
     └── Gate: RoadTerminusApronGate
P9c: Parametric Kerbs & Rumble Meshing
     └── Gate: RoadKerbMesherGate
P9d: Parabolic Crown & Superelevation Runoff
     └── Gate: RoadCrownRunoffGate
P9e: C² Spline Resampling & Clothoid Curvature Smoothing
     └── Gate: RoadSplineContinuityGate
P9f: Vertical G-Force / K-Value Solver Bounds
     └── Gate: RoadVerticalDynamicsGate
P9g: Bivariate Coons Patch Junction Surface
     └── Gate: RoadJunctionPatchGate
P9h: Dual-Topology Route (Closed Circuits & Lap Gates)
     └── Gate: RoadCircuitRouteGate
```

### Phase Details & Bench Gates

#### Phase P9a: Hybrid Driving Surface & Coplanar Mesh Pipeline
- **Deliverables**:
  - `Pasture3DRoadType.surface_mode` (`RIBBON_PHYSICS` vs `TERRAIN_DRAPED`).
  - Removal of geometric `DEPTH_LIFT` in favor of shader depth bias.
  - Dedicated driving `StaticBody3D` collider generation with `PhysicsMaterial` assignment and `Pasture3DSurfaceInfo` metadata.
  - Unconditional 3D bridge deck colliders on `is_bridge` intervals.
- **Gate**: `RoadDrivingSurfaceGate`
  - *Criteria*: Wheel contact point is within $0.001\text{ m}$ of rendered visual ribbon (control: legacy lift fails by $0.02\text{ m}$); bridge interval produces solid trimesh collider while terrain under it remains uncarved; off-road trail mode generates zero ribbon colliders.

#### Phase P9b: Bevelled Pavement Terminal Apron
- **Deliverables**:
  - Paved-to-unpaved terminal apron generator in `Pasture3DRoadMesher`.
  - Hermite downward transition bevel and rounded corner fillets.
- **Gate**: `RoadTerminusApronGate`
  - *Criteria*: End-cap vertices meet terrain heightfield with zero height discontinuity; normal of terminal apron smoothly transitions to ground normal; trimesh collision covers the ramp.

#### Phase P9c: Parametric Racing Kerbs & Rumble Geometry
- **Deliverables**:
  - Kerb parameters on `Pasture3DRoadType` and segment overrides on `Pasture3DRoadSegment`.
  - 4-vertex cross-section extrusion for kerbs in C++ (`road_mesh_build_chunk`) and GDScript oracle.
  - Sawtooth rumble strip vertex displacement $\delta(s)$.
- **Gate**: `RoadKerbMesherGate`
  - *Criteria*: Apex kerb exists on the authored side only; sawtooth profile matches exact target pitch $\lambda$ and height $A$; collision trimesh matches visual kerb displacement; non-kerbed road maintains standard shoulder.

#### Phase P9d: Parabolic Crown & Superelevation Runoff
- **Deliverables**:
  - `CrownMode` (`PARABOLIC`, `ONE_WAY_CROSSFALL`, `CIRCULAR_ARC`).
  - Elimination of $V$-crown crease; implementation of $z = -c(u/w)^2$.
  - Dynamic adverse crown attenuation $\eta(s)$ based on banking ratio.
- **Gate**: `RoadCrownRunoffGate`
  - *Criteria*: First derivative across centerline $dz/du\big|_{u=0} == 0.0000$ on straights; adverse crown attenuation reaches exactly $0.0$ on maximum banked corner (planar bank); One-Way Cross-Fall is strictly monotonic.

#### Phase P9e: $C^2$ Spline Continuity & Curvature Smoothing
- **Deliverables**:
  - Uniform 0.5m arc-length pre-sampler replacing `tessellate()`.
  - Continuous analytic tangent evaluator in C++ and GDScript.
  - Transition spiral curvature smoother bounding lateral jerk $d\kappa/ds$.
- **Gate**: `RoadSplineContinuityGate`
  - *Criteria*: Tangent vectors across spline joints are $C^1$ continuous; curvature derivative $|d\kappa/ds|$ does not exceed the transition spiral limit; lateral acceleration profile for a $200\text{ km/h}$ vehicle exhibits zero instantaneous step discontinuities.

#### Phase P9f: Vertical Dynamics & Velocity-Aware Limiter
- **Deliverables**:
  - Design-speed-dependent vertical curvature limits in `Pasture3DRoadAlignmentSolver` ($a_{\text{crest}} \le 0.4g$, $a_{\text{sag}} \le 0.6g$).
  - Second-difference clamping projection in SOR solve.
  - `allow_airborne_jump` override on `Pasture3DRoadSegment`.
- **Gate**: `RoadVerticalDynamicsGate`
  - *Criteria*: Solved profile over sharp hill does not exceed vertical acceleration limit at $v_{\text{design}}$ (control: increasing design speed flattens the crest); intentional jump segment preserves sharp crest; grade limit remains strictly satisfied.

#### Phase P9g: Bivariate Coons Patch Junction Surface
- **Deliverables**:
  - Transfinite interpolation Coons patch generator replacing radial triangle fan in `Pasture3DRoadMesher`.
  - Uniform grid interior triangulation with boundary fillet trimming.
- **Gate**: `RoadJunctionPatchGate`
  - *Criteria*: Interior junction mesh contains zero radial spoke creases; surface height and first derivatives at all arm boundaries match approach cross-sections; diagonal path across junction exhibits $C^1$ continuous elevation profile.

#### Phase P9h: Dual-Topology Racing Route
- **Deliverables**:
  - `RouteTopology` (`POINT_TO_POINT` vs `CLOSED_CIRCUIT`).
  - Lap wrapping, split sector timing gates, and seamless start/finish seam closure in `Pasture3DRoadRoute`.
  - Fast C++ spatial hash query `path_geom_locate` replacing GDScript linear loop.
- **Gate**: `RoadCircuitRouteGate`
  - *Criteria*: Lap counter increments on crossing start/finish gate; distance queries wrap seamlessly without negative delta at seam; sector gate split timestamps match vehicle trajectory; C++ spatial lookup matches brute-force oracle to within $10^{-5}\text{ m}$.

---

## 5. Architectural Summary & Conclusion

Implementing this specification transforms Pasture3D from a terrain grading tool into an industry-grade road and track creation suite. By combining:
- **Authoritative 3D ribbon colliders** (coplanar with visuals and full bridge support),
- **Procedural racing kerbs** (FIA bevels and physical rumble strips),
- **Crease-free parabolic crowns with superelevation runoff**,
- **$C^2$ continuous clothoid-smoothed splines and G-force bounded crests**,
- **Coons-patch smooth intersection surfaces**, and
- **Dual-topology (rally + circuit) race routing with C++ spatial indexing**,

Pasture3D will fully satisfy the rigorous mechanical, physical, and visual fidelity requirements expected in modern simcade racing games.
