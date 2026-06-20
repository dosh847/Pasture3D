# Pasture3D Brush — GPU Rasterisation Notes (Option D, future experiment)

Status: **research notes only**, not scheduled. To be tried on a separate experimental branch AFTER the
Round 2 native-C++ rasteriser (`PASTURE3D_BRUSH_PERF_ROUND2_SPEC.md`) lands — C++ may already make this
unnecessary except for extreme scenes. Captured 2026-06-20 so we don't re-research from scratch.

## Why GPU is the "industry" answer

The tools we're modelled on rasterise splines **on the GPU**, analytically:
- **MicroVerse** (Jason Booth, Unity real-time terrain): converts each spline to an **analytic SDF in a
  shader** (exact distance to the cubic Bézier per pixel, fixed cost, no sampling/chamfer). With
  per-spline caching + bounds culling he went **230 ms → 12 ms for 73 splines** (980ti); "~2/3 of the
  image is culled using only spline bounds." This is the canonical reference for our exact problem.
- **UE5 Landmass** (what our brushes imitate): spline brushes render via **Blueprint Brushes into GPU
  render targets**; a notable perf fix was *not rebuilding spline meshes unless the spline changed*
  (caching). UE5.7 also moved to non-destructive, layer-based deformation (parallels our layer stack).
- General pattern: **analytic SDF in a compute/fragment shader + cache the changed spline + cull by
  bounds.** We already do the caching (Stage 1 §3) and bounds culling (clip box); GPU replaces the
  per-pixel math with a massively-parallel analytic evaluation.

## The core architectural friction for US

MicroVerse/Landmass keep the result on the GPU because it only feeds *rendering*. Pasture3D's layers are
**CPU `Image`s** that are the source of truth for: the layer-stack composite, **physics collision**, and
the **saved `.res` files**. So a GPU rasteriser must **read back** the affected region(s) GPU→CPU to
stay authoritative. That readback (and keeping collision in sync) is the main cost/complexity GPU adds
for us that the reference tools don't pay.

→ GPU wins biggest when the edited area is large (the readback of a box is cheap relative to a huge
parallel SDF eval). For small edits the native-C++ path (Round 2) is already fast and avoids readback
latency entirely. So GPU is plausibly a *large-feature / very-heavy-scene* accelerator, not a default.

## Sketch of a Godot implementation

Godot exposes GPU compute via **`RenderingDevice`** + **GLSL compute shaders** (`.glsl`, not Godot's
shading language). A local `RenderingDevice` (`RenderingServer.create_local_rendering_device()`) can run
compute off the main render pipeline and read results back.

Pipeline per dirty-rect bake (replacing the §3 stamp call):
1. **Upload geometry**: the spline as a storage buffer — decimated polyline, or control points for
   analytic Bézier distance — plus params (height, falloff, blend, edge_offset, …) as a UBO/push const.
2. **Allocate an output texture** (R32F for height, R32_UINT for control) sized to the **tile-snapped
   clip box** (not the whole region — bounds culling).
3. **Dispatch compute** over the box: per texel compute signed distance (closed loop) or lateral
   distance + along-arc (open polyline) analytically, derive the profile/value, write to the output.
   Optionally also sample the current base height (uploaded as a texture) for `relative_to_terrain`.
4. **Read back** the output box to CPU (`RenderingDevice.texture_get_data`) and merge into the layer
   sample tiles (or feed a single `composite_area`).
5. Existing path continues: `composite_area` + `update_maps`.

Per-archetype shaders: one for **closed-loop SDF** (Mound/Plow/Splat) and one for **open polyline**
(Ridge/Trough), mirroring the two C++ archetypes — profile differences via uniforms/branches.

### Analytic distance
- Closed loop: even-odd inside test + min distance to edges, or a true Bézier SDF (MicroVerse-style)
  for smoothness. Per-pixel `O(edges)` but fully parallel; bounds-cull edges by a per-curve AABB UBO.
- Open polyline: min distance to segments + nearest-point arc length (for end taper), same culling.

## Open questions / risks to resolve on the experimental branch

- **Readback latency & sync.** `texture_get_data` stalls until the dispatch completes. Measure vs the
  C++ path; for small boxes C++ likely wins. Consider async readback / double-buffering for live drag.
- **Editor RenderingDevice access.** Confirm a local RD compute works reliably inside the *editor*
  (not just runtime), across the user's GPUs. Fallback to the C++ path if RD is unavailable.
- **Collision sync.** Collision reads the composited region heightmap; after readback + composite it's
  consistent, but verify timing (physics may read mid-edit).
- **Multi-region boxes.** A clip box spanning regions needs per-region output handling on readback.
- **Layer-stack composite stays CPU.** Either read back the raw layer samples and let the existing CPU
  `composite_area` run (simplest), or also composite on GPU (faster, but must replicate the blend stack
  on GPU and still read back for collision/save).
- **Precision.** Match FORMAT_RF (32-bit float); control is a packed uint32 (R32_UINT, exact).
- **Shader maintenance.** Two GLSL shaders to keep in sync with the C++/GDScript profile math (a third
  reference). Drift risk.
- **Per-edit setup cost.** Buffer uploads + pipeline binding per bake; amortise by caching the pipeline
  and reusing buffers.

## Decision guidance

- If Round-2 C++ brings the worst case to ~tens of ms → GPU is likely **not worth** the readback +
  shader-maintenance complexity; revisit only if users push very large features or huge spline counts.
- If even C++ leaves large-feature edits sluggish, GPU is the proven ceiling (MicroVerse-class numbers).
- A reasonable middle path is C++ + threading (Round 2 Phase 2) before GPU.

## References
- MicroVerse — Optimizing Spline Operations (Jason Booth): https://medium.com/@jasonbooth_86226/optimizing-spline-operations-d48b5f8fede4
- UE5 Landscape Blueprint Brushes: https://docs.unrealengine.com/4.27/en-US/BuildingWorlds/Landscape/Editing/SculptMode/Blueprint
- Godot compute shaders: https://docs.godotengine.org/en/latest/tutorials/shaders/compute_shaders.html
- Godot `RenderingDevice`: https://docs.godotengine.org/en/4.4/classes/class_renderingdevice.html
- Godot Compute Shader Heightmap demo (asset library #2784): https://godotengine.org/asset-library/asset/2784
- 2D SDF / distance-field background (prideout): https://prideout.net/blog/distance_fields/
