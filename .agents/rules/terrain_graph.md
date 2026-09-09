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

### E. Dimensionless Curvature & Turn Bounding
- **Strictly Dimensionless Curvature**: When calculating local curvature or turn angles (e.g. in `PathMeanderize`), always normalize incoming and outgoing segment vectors to unit directions:
  $$\text{turn} = \left(\frac{v_{\text{in}}}{\|v_{\text{in}}\|}\right) \times \left(\frac{v_{\text{out}}}{\|v_{\text{out}}\|}\right) = \sin(\theta_{\text{turn}}) \in [-1, 1]$$
- **Avoid Dimensional Runaway**: Never divide an unnormalized cross product $v_{\text{in}} \times v_{\text{out}}$ ($m^2$) by chord length ($m$) to obtain curvature. This yields a value in metres ($m$) rather than a dimensionless factor, causing displacement $disp = \text{chord} \cdot (\text{ratio} \cdot \text{turn} + \dots)$ to scale quadratically ($m^2$). Over multiple iterations, this compounds exponentially ($20\text{ m} \to 160\text{ m} \to 25,000\text{ m} \to 2.2\text{ million metres}$), exploding points across the viewport and collapsing splines upon loop excision.
- **C++ and GDScript Twin Parity**: Maintain identical normalization and $\epsilon$-guards across both C++ (`src/pasture_3d_path_ops.cpp`) and the GDScript `[Dev/GD]` reference node (`pasture3d_graph_node_dev_path_meanderize.gd`).

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

---

## 3. Color Nodes & Inline Previews (`ConstColor`, `ColorMix`, `ColorBlend`)

### A. Sideband Architecture & Spec Contracts
- **Decline Scalar Grid Lowering**: `PortType.COLOR` cannot flow through the SSA evaluator. `GraphEditorScript.preview_repr_for_type(PortType.COLOR)` must always return `-1`.
- **Topological Sideband Evaluation**: Evaluate color nodes via compile-time upstream traversal (`_resolve_color_node`) rather than SSA program execution.
- **Alpha Checkerboard Compositing**: Any color with $a < 1.0$ must be composited over an 8x8 checkerboard (`Color8(58,58,64)` / `Color8(38,38,44)`) before creating textures.

### B. Node-Specific Preview Rules
- **`ConstColor`**: Render a solid square matching `value: Color`. Range chip displays hex code (`#RRGGBB` or `#RRGGBBAA`).
- **`ColorMix`**: Compute folded color from upstream sources `a` and `b` using `mode` and `factor`. Range chip displays `MODE #HEX` (e.g., `MIX #800080`).
- **`ColorBlend`**:
  - **Wired Mask**: Piggyback the mask's SSA slot into the worker's `tap_slots` pass. Render a 2D blended thumbnail across the preview domain modulating Color A and Color B per-cell. Range chip displays `BLEND <MODE>`.
  - **Unwired Mask**: Fall back cleanly to uniform Color A with range chip `BLEND (unwired)` at dimmed opacity. Never freeze the main thread waiting for an unserved mask.

---

## 4. Channel Sinks (`ColorSink`, `ControlSink`) & Brush Invalidation

### A. Affiliated Layer Convention
- **Secondary Channel Owner IDs**: Channel sinks author into layers affiliated with the host brush, named `owner + "#graph_color"` and `owner + "#graph_control"` (or `owner + ":" + key`).
- **Multi-Layer Discovery**: Never assume a brush owns only one layer index. Use `_all_layers_for_owner(owner)` to discover all layers matching `owner` or starting with `owner + "#"`.

### B. Footprint Clearing & GPU Synchronization
- **Multi-Layer Clear Before Paint**: In `_refresh_owner_rect`, `_refresh_owner`, and `detach_placement`, clear dropped tiles across *all* affiliated layers (`clear_layer_in_area`) and composite back to base *before* painting.
- **Multi-Map Texture Pushes**: Check the layer stack for active overlays (`has_overlay_of_type`) and push `MAPTYPE_COLOR` and `MAPTYPE_CONTROL` via `update_maps()` whenever overlay layers exist.
- **Multi-Layer Undo/Redo Snapshots**: `_snapshot_owner` and `_restore_owner` must capture and restore tile dictionaries across all affiliated layers indexed by owner ID, preserving backwards compatibility with legacy `Vector2i`-keyed snapshots.

### C. Test Gate Invariants
- **Footprint Separation by Translation Symmetry**: When testing that brush movement clears previous footprints, ensure test sample points are outside the new position's footprint. Moving along a uniform displacement vector ($\vec{p}_1 = \vec{p}_0 + \vec{\delta}, \vec{p}_2 = \vec{p}_1 + \vec{\delta}$) guarantees non-overlap by translation symmetry.
- **Headless Scene Execution**: Automated bench gates extending `Node` must be accompanied by a `.tscn` root scene when executed under `--headless`.

---

## 5. Grid-to-Path Derive Nodes (`Pasture3DGraphNodePathDerive`) & Native Staging

When implementing or consuming derive nodes (`PathDrape`, `PathWidthFromField`, `PathFromFlow`):

### A. Phase S7b Staged Native Acceleration
- **Never Force GDScript Fallback for Staged Graphs**: Derive nodes read terrain fields and return `blocks_native() == true` for monolithic programs. However, when a graph modifier supports staged execution (`graph._native_supported_if_staged()`), `Pasture3DNodeGraph.forces_gdscript()` must return `false`.
- **Brush Host Preparation**: Host brushes (`Pasture3DPlow`, `Pasture3DMound`) must call `_prepare_staged_graph_modifiers()` to stage derive paths against the working base terrain (`_base_below_grid`) via `graph.stage_paths_for()` and compile `blk["graph_program"]` *before* invoking C++ native rasterization (`stamp_mound_loop`).
- **Prevent Main-Thread Stalls**: Dropping large terrain loops to the GDScript rasterizer falls back to computing SDFs and 2D blurs on the main thread, freezing the editor for 12+ seconds. Staged native execution runs in $< 200\text{ ms}$ (a $70\times$ speedup).

### B. Unwired Surface Input Fallback
- **Ambient Input Fallback**: If a derive node's `surface` port is unwired, both `_stage_derives()` and `_input_grids()` must fall back to the host brush's incoming terrain surface (`p_input`), rather than passing the path through unmodified.
- **Clear Diagnostic Messaging**: Diagnostic warnings in `node_warnings()` must inform the user when an unwired surface port is defaulting to the incoming terrain surface.

---

## 6. Path Carve & Composition Presets (`Pasture3DGraphNodePathCarve`)

### A. Cross-Section & Blend Coupling Invariant
- **Auto-Switching Compatible Blends**: `PathCarve.blend` defaults to `Blend.MAX` for `CrossSection.CREST`. For `CrossSection.BED`, `Blend.MAX` will clamp negative carved depths back to ground level ($\max(\text{carved}, \text{ground}) = \text{ground}$), completely erasing the channel. The `cross_section` setter must automatically switch `blend` to `Blend.MIN` when `BED` is selected, and to `Blend.MAX` when `CREST` is selected.
- **Diagnostic Incompatibility Warnings**: `node_warnings()` must emit an immediate warning if `cross_section == CrossSection.BED && blend == Blend.MAX` or `cross_section == CrossSection.CREST && blend == Blend.MIN`.

