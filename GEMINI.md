# Pasture3D Engineering Guidelines & Workspace Rules

## 1. Road & Geometry Engineering Standards
- **Real-World Roads over Race Tracks**: Road procedural generation must follow civil engineering principles rather than uniform racing-track splines.
- **Mountain & Hairpin Handling**: Road solver and mesher must support tight hairpin switchbacks with elevation gain:
  - Isolate curvature and banking transitions to avoid pre-curve banking on straights.
  - Apply mountain banking caps (default max 0.04 rad / 2.3°) on steep grades to prevent low-speed rollover.
  - Apply hairpin grade compensation (reducing slope at the apex where inner radii tighten).
  - Apply curve widening at tight curve apexes.
- **Watertight Junctions**: Multi-arm intersections must use $C^1$ continuous transfinite Coons patches with regular interior grids rather than radial spoke triangle fans.

## 2. Headless Test Gate Discipline (`project/bench/`)
- **Strictly Headless Compatible**: All gate scenes must execute cleanly with `--headless`:
  - Never await `RenderingServer.frame_post_draw` without display server (causes runner to stall indefinitely). Use `process_frame` or synchronous evaluations.
  - Every gate must conclude with `get_tree().quit(0 if _fail == 0 else 1)`.
- **Active Negative Controls**: Every test criterion must test active negative controls (e.g., perturbed values, reversed traversal, broken seams) asserting that bad states trigger failures.
- **Gate Registration**: Working gates must be documented and registered in `project/bench/gates.txt`.

## 3. Godot 4 GDScript & GDExtension Conventions
- **GDExtension Static Method Reflection**:
  - Always use `ClassDB.class_has_method("ClassName", "method_name")` to check C++ extension methods in GDScript.
  - Never call `ClassName.has_method(...)` or `ClassDB.has_method(...)` on class names (causes parse errors).
- **String Formatting**:
  - GDScript format strings do NOT support `%e` for scientific notation. Use `%.6f`, `%.8f`, or custom string conversions.
- **Tool Artifact Path Invariant**:
  - Never pass `ArtifactMetadata` to `write_to_file` when creating or modifying codebase/project files. `ArtifactMetadata` is reserved strictly for markdown artifacts located in the brain artifact directory.
