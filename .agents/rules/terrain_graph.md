# Pasture3D Terrain Graph Rules

## 1. Path Reshape Nodes (`Pasture3DGraphNodePathShape`)

When implementing or modifying path reshaping nodes (e.g. `PathMeanderize`, `PathFractalize`, `PathResample`, `PathSmooth`):

### A. Point Density & Subdivision Control
- **Prevent Exponential Inflation**: Never perform unconditional edge subdivision inside an iteration loop ($N \cdot D^{it}$).
- **Spacing Floor**: Provide a physical `@export var min_segment_length: float` (in metres) below which segments are never subdivided.
- **Support In-Place Iteration**: Allow `@export var edge_divisions: int` to be `1` (the default for bend/meander iteration), so iterations amplify shape without adding vertices.
- **Respect Input Density**: Relax initial pre-subdivision passes ($\max(\lambda / 4, \text{min\_segment\_length})$) so already-resampled paths are not unnecessarily densified.

### B. Physical Scale in Metres vs. Discrete White Noise
- **Units in Metres**: Always parameterize feature scale in metres (`wavelength`, `amplitude`, `sigma`). Never use segment fractions, tile fractions, or vertex counts as proxies for world distance.
- **Continuous Functions along Arc Length**: Use continuous mathematical waves ($\sin(2\pi s / \lambda)$) and 1D continuous noise along cumulative arc length $s$, rather than uncorrelated independent Gaussian white noise at each midpoint.
- **Density Invariance**: A path resampled to 1m spacing and a path sampled at 20m spacing must both develop the same macro-scale physical features under the same `wavelength`.

### C. Endpoints & Closed Loop Invariants
- **`pin_ends` Contract**:
  - When `pin_ends == true` on open paths, smoothly taper perpendicular displacements to 0 at the endpoints (e.g. using smoothstep over $\min(\lambda, L \cdot 0.35)$).
  - When `pin_ends == false`, endpoints must be displaced smoothly along adjacent edge normals.
- **Closed Seam Wrapping ($C^0$ Continuity)**:
  - On closed loops (`p_src.closed == true`), dynamically adjust wavelength so an integer number of waves fit around the perimeter:
    $$m = \max(1, \text{round}(L / \lambda)), \quad \lambda_{\text{adj}} = L / m$$
  - Wrap periodic noise cells so $(P_{N-1}, P_0)$ has seamless continuity.
- **Attribute Projection Across the Seam**:
  - In `carry_values()`, always evaluate all $N$ segments including $(P_{N-1}, P_0)$ on closed loops to prevent seam gaps or NaN attribute interpolations.

### D. Parameter Conventions
- Export setters must call `_param_changed()` (not raw `emit_changed()`) to bump the graph's dirty revision and notify the canvas.

---

## 2. Viewport Gizmo & Spline Previews

### A. Single Active Version Rule
- The 3D viewport overlay must display strictly **one version of a path at a time** across a brush, avoiding multi-node wireframe accumulation.
- Resolve the active node using the priority cascade:
  1. **Solo Override (`g.output_override >= 0`)**: Highest priority. Previews the soloed node (or upstream PATH node feeding it).
  2. **Selected Node (`_editor_selected_node` metadata)**: Previews the node currently selected on the `GraphEdit` canvas.
  3. **Explicit Preview (`preview_on`) / Output Node**: Fallback for pinned previews and headless test fixtures.

### B. Editor State Synchronization
- Connect `node_selected` and `node_deselected` in `GraphEdit` to update `_editor_selected_node` on the graph resource and call `brush.update_gizmos()`.
- Clear `_editor_selected_node` when switching or unloading graphs in `edit_graph()`.
