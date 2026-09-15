# Pasture3D Terrain Graph — Gradient, Value Ramp and Color Ramp Nodes Spec

**Status:** Phase 1 built and gated (2026-09-14, commit 3baf1794; its GLSL rode in e23e8c3a).
`GraphDistanceMetricGate` passes windowed with every control live: the C++ Falloff is bit-identical in 64 of
64 cases, and the GPU matches within 1e-5 m (the DM-B amendment). Phase 2a built and gated (2026-09-14,
commit 337bb27c): `lut_buf_of()` + GLSL `p3d_lut` on binding `c`, `GKM_CURVE = 35`, Path Carve moved onto
the helper; `GraphCurveGpuGate` passes with a slope-scaled tolerance. Phase 2b audit done (2026-09-14,
commit d1758a14): outcomes in §9.1; Strata moved to GPU (`GKM_STRATA = 36`) and its dropped terrace profile
fixed. Phase 2c built and gated (2026-09-14, commit 7604db27): Gradient, op 62, `gradient_grid` +
`gradient_frame`, `GKM_GRADIENT = 37` (push-constant pads became `f8` / `f9`), `[Dev/GD] Gradient`, host
placement stamped by `Pasture3DGraphSources.resolve_host_placements`; `GraphGradientGate` passes windowed,
GR-A to GR-K, every control live. §4.3 and §4.4 carry Phase 2c amendments. Phase 3 built and gated
(2026-09-14, commit 7530cdf8): `src/pasture_3d_ramp_eval.h`, Value Ramp op 63, `value_ramp_grid`,
`GKM_VALUE_RAMP = 38` over `GRAPH_RAMP_EVAL_GLSL`, `[Dev/GD] Value Ramp`; `GraphValueRampGate` passes
windowed, VR-A to VR-J, every control live. §5.3 and VR-B carry Phase 3 amendments. Phase 4 built and gated
(2026-09-14, uncommitted): Color Ramp (no op id), `Pasture3DUtil.color_ramp_cells`, base
`color_field_port()`, `Pasture3DGraphNodeValueRamp.stops_of` shared by both ramps, the editor's per-cell
colour preview generalised from Color Blend to any `graph_color_cells` node; `GraphColorRampGate` passes,
CR-A to CR-I, every control live. CR-G carries a Phase 4 amendment. Phase 5 is unbuilt. Check
the symbols named in §10 before planning from this header, which will go stale.

**Decisions taken before writing:**

* **Shared distance math.** Falloff and Gradient measure distance through ONE function per evaluator.
  Falloff is refactored first and must come out bit-identical.
* **Gradient placement is host-relative by default.** A `space` setting chooses World or Host. Host follows
  the brush's position and yaw.
* **The ramp is two nodes.** *Value Ramp* is a scalar node (Mask or Height mode) that runs natively, fuses
  per cell and runs on the GPU. *Color Ramp* has one COLOR output, in the per-cell form Color Sink already
  reads.
* **The ramp colour space follows the colour map.** New gradients default to sRGB, because the terrain
  shader samples `_color_maps` as `source_color`. sRGB, linear sRGB and Oklab interpolation are all
  supported.
* **The Curve node gets a GPU mode** (Phase 2a), built on a shared GPU lookup-table binding. An audit of
  the other lookup-table nodes follows and moves them onto it (Phase 2b), **before** Phase 3's new C++ work.
* **No viewport gizmos, and no RGBA program buffers** (§10).

---

## 1. Why

1. **There is no gradient generator.** A slope, valley, dome or crater bowl is built today by applying a
   Falloff to a Const. That cannot make a signed linear ramp, a ridge or a spherical cap, and it cannot
   follow a brush.
2. **There is no multi-stop remap.** Remap is a two-point linear map and Curve is one transfer function.
   Neither expresses "rock below 0.3, grass to 0.6, snow above" as crisp bands, and nothing turns a scalar
   field into a colour except the two-colour Color Blend.

## 2. How other tools do it (research summary)

* **Gradients.** Blender, Photoshop and Houdini each use one node with a shape enum. Profile shaping lives
  on the node (Unreal's hardness, Gaea's falloff). Houdini has repeat and mirror modes. World Machine and
  Photoshop use a two-point definition. Blender and Houdini warp the coordinate through an input.
* **Ramps.** Blender's Color Ramp has Constant interpolation for crisp bands. Photoshop maps luminance to a
  gradient. Gaea and World Machine ship earth-tone presets. Godot's `Gradient` resource provides the stops,
  Linear / Constant / Cubic interpolation, an interpolation colour space and an inspector editor.

---

## 3. Shared distance math (Phase 1 — refactor, no new node)

### 3.1 The problem it removes

Falloff's distance is defined three times:

| Evaluator | Location |
|---|---|
| GDScript oracle | `Pasture3DGraphNodeFalloff.attenuation()` (`graph/pasture3d_graph_node_falloff.gd`) |
| Native C++ | `falloff_grid()` (`src/pasture_3d_math_ops.h` / `.cpp`) |
| GPU | the `GKM_FALLOFF` block of `GRAPH_GRID_GLSL_1B` (`src/pasture_3d_graph_gpu.cpp`) |

Adding Gradient without this refactor would make six copies.

### 3.2 One metric vocabulary

```
enum DistanceMetric {
    RADIAL    = 0,  // |p - a|                                    (Falloff RADIAL)
    SQUARE    = 1,  // max(|dx|, |dz|)                             (Falloff SQUARE)
    AXIS_X    = 2,  // |dx|                                        (Falloff AXIS_X)
    AXIS_Z    = 3,  // |dz|                                        (Falloff AXIS_Z)
    LINEAR    = 4,  // signed projection of (p - a) onto unit(b - a)
    REFLECTED = 5,  // |LINEAR|
    DIAMOND   = 6,  // |dx'| + |dz'| in the frame of (b - a)
    ANGULAR   = 7,  // atan2 sweep about a, from direction (b - a), in [0, 2π)
}
```

Values 0–3 are exactly Falloff's serialised `Shape` values. Append only.

Every metric takes `(wx, wz, ax, az, ux, uz)`: a world point, an origin in metres, and a **unit
direction** `u`. Metrics return METRES, except ANGULAR, which returns radians. The caller normalises.

**Amended during Phase 1: a unit direction, not an end point `b`.** The first draft passed `b` and derived
the direction inside the metric, with Falloff passing `b = a + (1, 0)`. That breaks Falloff's bit-identity:
`(ax + 1) − ax` is not exactly 1 once `ax` is large, so every off-origin SQUARE falloff would move by a few
ulps. Now Falloff passes the literal `u = (1, 0)`, for which the frame rotation `x' = dx·ux + dz·uz` is
exact. Gradient derives `u` once per lowering through `p3d_metric_direction(a, b)` /
`Pasture3DGraphDistance.direction(a, b)`, which is the ONE place the |b − a| < 1e-6 m → +X fallback is
defined. The GPU never sees `b`; it receives the direction the C++ host derived.

An out-of-range Falloff shape stays RADIAL (the old switch's `default:`). Both Falloff kernels guard
shapes > 3 explicitly, so metrics 4–7 cannot leak into a Falloff.

### 3.3 One definition per evaluator

| Evaluator | Single home | Callers |
|---|---|---|
| C++ | `src/pasture_3d_distance_metric.h`: `inline double p3d_distance_metric(int, double wx, double wz, double ax, double az, double bx, double bz)` | `falloff_grid`, `gradient_grid` |
| GLSL | `static const char *GRAPH_DISTANCE_METRIC_GLSL`, concatenated **once** ahead of the grid kernels | `GKM_FALLOFF`, `GKM_GRADIENT` |
| GDScript | `graph/pasture3d_graph_distance.gd`: `class_name Pasture3DGraphDistance`, `static func metric(...)` | `Falloff.attenuation`, the Gradient oracle |

The GDScript copy is the oracle and is written independently of the C++ copy. A parity gate against
`evaluate()` compares the kernel with itself (§8).

**Precision.** GPU params are float32, so world coordinates lose centimetre precision beyond about 16 km.
When a resolved coordinate exceeds 16 000 m, raise a node warning; don't let CPU and GPU diverge silently.

### 3.4 Phase 1 gate — `GraphDistanceMetricGate`

| Id | Criterion | Control that must fail |
|---|---|---|
| DM-A | Falloff, all 4 shapes, native CPU: **bit-identical** to a `.res` baseline captured from `main` before any code change. The gate never regenerates it | The baseline with `feather` +1 m must differ |
| DM-B | GPU Falloff through a direct `graph_eval_grid_gpu` call: each case bit-identical to the baseline **or** within 1e-5 m of the CPU result with the same NaN cells. *(Amended 2026-09-14, by decision: moving the metric into a shared GLSL function changed float32 rounding in the 16 soft-feather + noise cases by up to 6.2e-6 m, 3–4 ulps, the same class as the pre-refactor CPU/GPU gap. Forcing the old bits would mean inlining the metric per kernel, which is the duplication this phase removes. DM-A still holds the CPU to bits.)* | A GPU-refused program must come back empty, so a refusal is recognisable; and feather +1 m on the GPU must land **outside** the 1e-5 m tolerance, so the tolerance can still see a real change |
| DM-C | GDScript metric vs C++ metric (`Pasture3DUtil.graph_distance_metric_grid`, a gate-only binding), 257×257 at ~2 km coordinates, off-axis direction, all 8 metrics, within 1e-3 m (float32 grid) / 1e-5 rad | The C++ grid with `u` **negated** must disagree with the oracle and equal −oracle for LINEAR. *(Amended: "swap a and b" gives L − x, not −x, so it was a control for the wrong claim.)* |
| DM-D | `a == b`: the C++ direction falls back to +X and matches the oracle's fallback. The GPU receives the host's direction, so it has no fallback of its own | The oracle measured along +Z must not match |
| DM-F | Repeat modes: oracle vs C++ (`graph_repeat_values`) over [−3, 3] plus NaN, within 1e-5; NaN passes through | C++ MIRROR compared against oracle REPEAT must differ by > 0.5 |
| DM-E | Every criterion reported. Headless, DM-B is SKIPPED and the verdict is PARTIAL, never PASS | — |

---

## 4. Gradient node (Phase 2)

`Pasture3DGraphNodeGradient`, `graph/pasture3d_graph_node_gradient.gd`, op `&"gradient"`,
`GRAPH_OP_GRADIENT = 62`.

### 4.1 Role and shape

**GENERATOR, CELL node** (`needs_grid() = false`), with **one output** whose type follows `output_mode`. A
second output would force a grid node and lose fusion.

### 4.2 Parameters

```
enum Space { HOST, WORLD }                                                     # serialised: append only
enum Shape { LINEAR, REFLECTED, RADIAL, SPHERICAL, SQUARE, DIAMOND, ANGULAR }
enum Profile { LINEAR, SMOOTH, EASE_IN, EASE_OUT, EXPONENTIAL, CURVE }
enum Repeat { CLAMP, REPEAT, MIRROR }
enum OutputMode { MASK, HEIGHT }
```

| Group | Property | Meaning |
|---|---|---|
| — | `shape: Shape = RADIAL` | Picks the metric and its normalisation (§4.4) |
| Placement | `space: Space = HOST` | HOST: `start` / `end` are metres relative to the host brush (§4.3). WORLD: absolute world metres |
| Placement | `start: Vector2 = (0, 0)` | The linear origin, or the radial centre |
| Placement | `end: Vector2 = (500, 0)` | The linear t = 1 point, or any point on the radius |
| Profile | `profile: Profile = LINEAR` | Shaping on normalised t |
| Profile | `hardness: float = 2.0` | EXPONENTIAL exponent, range [0.05, 16] |
| Profile | `curve: Curve` | Used when `profile == CURVE`. Lowered to a 256-entry LUT and evaluated on the GPU through the Phase 2a binding |
| Profile | `repeat: Repeat = CLAMP` | Applied before the profile |
| Profile | `invert: bool = false` | t → 1 − t after the profile |
| Output | `output_mode: OutputMode = MASK` | MASK is [0, 1]. HEIGHT is lerp(`height_min`, `height_max`, t) |
| Output | `height_min = 0.0`, `height_max = 100.0` | Metres, HEIGHT mode only |
| Warp | `distance_noise: float = 0.0` | Metres of perturbation from the `warp` port |

Connect `curve.changed` in the setter. Chain `super()` in any `_init`.

### 4.3 Host space

A graph is a Resource and cannot reach the scene, so the host places it from outside.

* **One entry point.** `Pasture3DGraphSources.resolve(graph, host)` (`graph/pasture3d_graph_sources.gd`)
  already fills every scene-naming source, from the brush step, the editor preview and the inspector
  hand-off. It is extended to stamp a **host placement** onto every node that implements
  `set_host_placement(p_xform: Transform2D)`. No call site changes.
* **What the placement holds.** The host's world XZ origin and its **yaw** (rotation about Y), taken from
  its `global_transform`. Pitch, roll and scale are dropped: a gradient is measured in metres on the ground
  plane, so a scaled brush does not stretch a 500 m slope.
* **Where it is applied.** *Amended in Phase 2c.* `native_lower()` lowers `start` / `end` in the node's
  space plus the placement (slots 13–15: origin x, z, yaw), and `gradient_frame()` in C++ places them. It
  cannot happen in `native_lower()`, because a driven `start_x` is resolved into the param block after
  lowering and must be transformed exactly like the property. The GPU planner calls the same
  `gradient_frame()` in double, so the metric (§3) still only ever sees world coordinates.
* **Invalidation.** `set_host_placement` emits `changed` **only when the placement differs** (compared
  within 1e-4 m / 1e-5 rad). Without the change signal, a moved brush reuses a stale compiled program.
  With a signal on every resolve, the cache never holds.
* **No host.** When a graph is evaluated without a host (a gate, an export), the placement is identity. A
  HOST-space Gradient that has never received a placement shows a node warning. It still evaluates, as
  world space.

### 4.4 Normalisation: shape → metric → t

`L = |end − start|`, floored at 1e-3 m.

| Shape | Metric | t before repeat |
|---|---|---|
| LINEAR | LINEAR | `d / L` |
| REFLECTED | REFLECTED | `d / L`: a valley, 0 on the line. Invert for a ridge |
| RADIAL | RADIAL | `1 − d / L` |
| SPHERICAL | RADIAL | `u = d / L` is repeated, then `sqrt(max(0, 1 − u²))`. Folding `1 − d/L` instead agrees only at L/2 (a Phase 2c bug GR-D caught at d = L) |
| SQUARE | SQUARE (frame of end − start) | `1 − d / L` |
| DIAMOND | DIAMOND | `1 − d / L` |
| ANGULAR | ANGULAR | `d / 2π` |

`d` includes `distance_noise * warp`. For ANGULAR the warp is scaled by `1 / L` into radians.

Repeat: CLAMP → `clamp(t, 0, 1)`. REPEAT → `fract(t)`. MIRROR → `1 − |fract(t / 2) * 2 − 1|`. The repeat
function is shared with the ramps (§5.2) and defined once per evaluator next to the distance metric.

Profile: LINEAR → t. SMOOTH → smoothstep. EASE_IN → t². EASE_OUT → 1 − (1 − t)². EXPONENTIAL →
t^hardness. CURVE → LUT[t].

### 4.5 Ports

| # | Name | Type | Unwired |
|---|---|---|---|
| 0 | `warp` | FIELD (aux grid) | zero buffer |
| 1 | `start_x` | FLOAT | `start.x` |
| 2 | `start_z` | FLOAT | `start.y` |
| 3 | `end_x` | FLOAT | `end.x` |
| 4 | `end_z` | FLOAT | `end.y` |
| 5 | `height_min` | FLOAT | `height_min` |
| 6 | `height_max` | FLOAT | `height_max` |

A driven `start_*` / `end_*` value is in the node's `space`, and is transformed like the property.

Changing `output_mode` calls `notify_property_list_changed()` and refreshes the slot colour.

### 4.6 Warnings

* CURVE profile with no curve: LINEAR is used.
* `|end − start| < 1e-3`: degenerate.
* HOST space with no placement received (§4.3).
* A resolved coordinate beyond 16 km (§3.3).
* HEIGHT mode with `height_min == height_max`.

### 4.7 Evaluators

* **GDScript [Dev/GD]**: `eval_cell` via `Pasture3DGraphDistance`. It is the oracle, behind the dev flag.
* **C++**: `gradient_grid()`, `GRAPH_OP_GRADIENT`. **Add `"gradient"` to `graph_op_ids()`.**
* **GPU**: `GKM_GRADIENT`, with the CURVE profile read from the Phase 2a LUT binding. No GPU refusal.

### 4.8 Phase 2 gate — `GraphGradientGate`

| Id | Criterion | Control that must fail |
|---|---|---|
| GR-A | Oracle vs native, 7 shapes × 3 repeats × 6 profiles, within 1e-5 | Oracle with `invert` toggled |
| GR-B | Native vs GPU (direct call, route checked), same sweep including CURVE, within 1e-4 | As DM-B |
| GR-C | Metric invariance: 1 m and 4 m bakes agree at shared world points within 1e-4 | A kernel copy that scales `L` by cell size |
| GR-D | SPHERICAL at d = L/2 is `sqrt(0.75)` ± 1e-5, and 0 for d ≥ L | RADIAL at d = L/2 |
| GR-E | Swapping `start` / `end` on LINEAR + CLAMP gives `1 − t` | — |
| GR-F | Gradient → Blend compiles to one cell program (check the plan) | A forced `needs_grid() = true` copy |
| GR-G | A driven `end_x` moves the native result | A Const equal to the property must not |
| GR-H | **Host follows the brush:** a HOST-space gradient on a brush moved +200 m in X and yawed 90° bakes the same field moved and rotated, within 1e-4 at mapped points. Read from the terrain after the bake, not from the node | The same fixture in WORLD space must NOT move |
| GR-I | **Invalidation is exact:** moving the host bumps the graph revision once; resolving again with an unchanged placement does not bump it | — |
| GR-J | Brush scale 2× does not change a HOST gradient's metre length | A copy that applies the full basis must fail |
| GR-K | Completion count ≥ 10 | — |

---

## 5. Ramp core (shared by both ramps)

### 5.1 Stops, interpolation and colour space

Both ramps take a Godot `Gradient` and evaluate it **exactly**, with no 256-entry LUT. On a 100 m window, a
LUT smears a CONSTANT band edge by 0.4 m.

* **Lowering.** The stops are packed into `lut` as `[offset, r, g, b, a] × N`, sorted by offset.
  `params[0] = N`, `params[1] = interpolation_mode` (LINEAR / CONSTANT / CUBIC),
  `params[2] = interpolation_color_space` (SRGB / LINEAR_SRGB / OKLAB). Colours are stored as the resource
  holds them, in sRGB.
* **Lookup.** A binary search on the offsets.
* **CONSTANT.** The colour of the greatest stop whose offset ≤ t. **At equal offsets the later stop in
  sorted order wins.** The rule is written once here and gated in both authoring orders.
* **LINEAR / CUBIC.** Convert the bracketing stops into the interpolation space (identity for SRGB; sRGB →
  linear for LINEAR_SRGB; sRGB → linear → Oklab for OKLAB), interpolate, and convert back to sRGB. CUBIC
  uses Godot's formula. Transcribe `Gradient::get_color_at_offset` and its colour-space helpers from the
  **pinned** engine source, with file and line cited in the kernel.
* **Outside the stops.** Below the first stop: the first colour. Above the last: the last colour. An empty
  or null gradient outputs `t` (Value Ramp) or grey `t` (Color Ramp), with a warning.
* **Default colour space.** A gradient created by either node's inspector is initialised with
  `interpolation_color_space = GRADIENT_COLOR_SPACE_SRGB`. The colour map is sampled as `source_color`
  (`src/shaders/main.glsl`), so sRGB is the space its texels are authored in. That is also Godot's default,
  so a user-assigned gradient is not rewritten. The spec states it so the choice is on record, not
  inherited by accident.

### 5.2 Input window

`input_min` / `input_max` map onto offset [0, 1], followed by the shared `repeat` (§4.4). An empty window
(min == max) maps everything to offset 0, with a warning.

### 5.3 One implementation per evaluator

| Evaluator | Home |
|---|---|
| C++ | `src/pasture_3d_ramp_eval.h`: `p3d_ramp_sample(stops, n, mode, space, t) -> Color` |
| GLSL | `GRAPH_RAMP_EVAL_GLSL`, reading the stops from the Phase 2a LUT binding |
| GDScript oracle | **`Gradient.sample(t)`**, so the engine itself is the reference. It is not a transcription |

**Phase 3 amendments.**

* **Lowering order.** `stop_table()` calls `gradient.sample(0.0)` before reading `offsets` / `colors`. That
  runs the engine's lazy sort, so the table is in the order `get_color_at_offset` searches. That order is
  what settles an equal-offset tie. The engine's own rule is kept as transcribed, including its exact-hit
  early return. VR-C confirms in both authoring orders that it returns the later sorted stop past the tie.
* **GPU exact hit.** The GLSL search treats `|offset - t| ≤ 4e-7` as an exact hit. A round-number window
  (−20 .. 80, x = 60) puts t exactly on the 0.8 stop on the CPU. On the device, the float division landed
  one ulp short, so every CONSTANT case flipped a band at that cell. The C++ search stays exact. A CPU t
  within 4e-7 of a stop but not on it is the case left unmatched.
* **Default colour space.** Not initialised by the node. A null gradient passes t through, and a
  `Gradient.new()` is already SRGB, so the §5.1 default holds without code.

---

## 6. Value Ramp node (Phase 3)

`Pasture3DGraphNodeValueRamp`, `graph/pasture3d_graph_node_value_ramp.gd`, op `&"value_ramp"`,
`GRAPH_OP_VALUE_RAMP = 63`.

### 6.1 Role and shape

**FILTER, CELL node** (`needs_grid() = false`), with one output. It fuses into the per-cell program, runs
natively and on the GPU, and is the node used to drive height from a gradient.

### 6.2 Parameters

```
enum OutputMode { MASK, HEIGHT }                                  # serialised: append only
enum Channel { AVERAGE, LUMINANCE, RED, GREEN, BLUE, ALPHA }
```

| Group | Property | Meaning |
|---|---|---|
| — | `gradient: Gradient` | Stops (§5.1). `changed` connected in the setter |
| — | `channel: Channel = AVERAGE` | Reduces the sampled colour to a scalar. AVERAGE = (r+g+b)/3, so no hidden weights; LUMINANCE = 0.2126r + 0.7152g + 0.0722b. The colour space affects **interpolation only**; the channel is read from the sRGB result |
| Input window | `input_min = 0.0`, `input_max = 1.0`, `repeat = CLAMP` | §5.2 |
| Output | `output_mode: OutputMode = MASK` | MASK: the channel value clamped to [0, 1]. HEIGHT: lerp(`height_min`, `height_max`, value) in metres |
| Output | `height_min = 0.0`, `height_max = 100.0` | HEIGHT mode only |
| — | `amount = 1.0` | Blends from the normalised input t (0) to the ramp value (1), before the output mapping |

`@export_tool_button("Auto Fit Range")`. Changing `output_mode` refreshes the slot type, as in §4.5.

### 6.3 Ports

| # | Name | Type | Unwired |
|---|---|---|---|
| 0 | `in` | HEIGHT | zeros, with a warning |
| 1 | `in_min` | FLOAT | `input_min` |
| 2 | `in_max` | FLOAT | `input_max` |
| 3 | `height_min` | FLOAT | `height_min` |
| 4 | `height_max` | FLOAT | `height_max` |
| 5 | `amount` | FLOAT | `amount` |

Output 0: MASK or HEIGHT per `output_mode`.

### 6.4 Evaluators

* **GDScript [Dev/GD]**: the oracle, via `Gradient.sample`.
* **C++**: `value_ramp_grid()` over `p3d_ramp_sample`, `GRAPH_OP_VALUE_RAMP`. **Add to `graph_op_ids()`.**
* **GPU**: `GKM_VALUE_RAMP` over `GRAPH_RAMP_EVAL_GLSL`. No refusal.

### 6.5 Phase 3 gate — `GraphValueRampGate`

| Id | Criterion | Control that must fail |
|---|---|---|
| VR-A | Native vs `Gradient.sample`, 3 modes × 3 colour spaces × 3 repeats × 6 channels, 4097 t, within 1e-5 (CUBIC and OKLAB within 1e-4) | A kernel copy using a 256-LUT must fail CONSTANT at a band edge |
| VR-B | CONSTANT edge exact: stop at 0.5; t = 0.5 ± 1e-6 fall in different bands, native and GPU. *Amended:* a round-number window landing exactly on a stop (x = 60 on −20 .. 80, the 0.8 stop) agrees across native, GPU and oracle | — |
| VR-C | Equal-offset tie, both authoring orders; native, GPU and oracle all return the later stop | A kernel with the earlier-stop rule |
| VR-D | Colour space matters: a red→blue gradient at t = 0.5 differs between SRGB and OKLAB by more than 0.05 on `channel = RED`, and each matches the oracle | A kernel that ignores `params[2]` must fail the OKLAB half |
| VR-E | Native vs GPU (direct call, route checked), within 1e-4 | As DM-B |
| VR-F | HEIGHT mode drives the terrain: Value Ramp → Output on a brush writes `lerp(height_min, height_max, v)` metres, read from terrain data | MASK mode on the same fixture must differ |
| VR-G | Fusion: In → Value Ramp → Output compiles to one cell program | A forced grid copy |
| VR-H | An in-place `gradient.set_color` invalidates (the second bake differs) | — |
| VR-I | `amount = 0` in MASK mode returns the normalised input | `amount = 0.01` |
| VR-J | Completion count ≥ 9 | — |

---

## 7. Color Ramp node (Phase 4)

`Pasture3DGraphNodeColorRamp`, `graph/pasture3d_graph_node_color_ramp.gd`, op `&"color_ramp"`.
**No native op id and no `graph_op_ids()` entry.** The node has no scalar output, so, like Color Blend and
Color Mix, it never lowers and cannot cost a graph its native route.

### 7.1 Role and shape

**COMBINER-style colour node** (the same role as Color Blend), with **one output: `color` (COLOR)**. It
travels the colour sideband and is read by Color Sink through `color_at(values, cell)`, like every other
colour source. Colour Sink needs no change.

### 7.2 Scalar-to-colour conversion (the support this adds)

Color Blend already converts a scalar field into a per-cell colour, but only as a choice between two
colours, and its hook names reflect that. The Color Ramp makes the conversion a first-class contract:

* **`color_field_port() -> int`** is a new base method on `Pasture3DGraphNode`. It names the scalar input
  the colour resolver must tap. `color_mask_port()` stays as Color Blend's name. The base implementations
  forward to each other, and `graph_channel_sinks.gd::_color_of` calls `color_field_port()` only. Color
  Blend therefore needs no change, and new converters don't borrow a mask-shaped name.
* **`graph_color_cells(upstream, field, n) -> PackedColorArray`** is unchanged. It is the conversion
  itself.
* **Native fast path.** Mapping every cell in GDScript is the cost that matters on a large bake. Color
  Ramp's `graph_color_cells` calls a bound C++ helper,
  `Pasture3DUtil.color_ramp_cells(field, stops, n, mode, space, in_min, in_max, repeat) -> PackedColorArray`,
  which runs `p3d_ramp_sample` (§5.3). The tapped pass is still the Color Blend price, but the per-cell
  mapping is native. The GDScript `Gradient.sample` loop remains as the [Dev/GD] oracle.
* **Wiring.** COLOR already connects only to COLOR: it is absent from the cross-type pairs in
  `graph_editor.gd`'s `add_valid_connection_type` table. So a Color Ramp cannot be wired into a HEIGHT port,
  and CR-G guards that as a regression.

### 7.3 Parameters

| Group | Property | Meaning |
|---|---|---|
| — | `gradient: Gradient` | §5.1, default colour space sRGB |
| Input window | `input_min = 0.0`, `input_max = 1.0`, `repeat = CLAMP` | §5.2 |
| — | `strength = 1.0` | Scales output alpha, which is the colour overlay's coverage (see Color Sink's header). 0 paints nothing |

**Uniform fallback.** `graph_color(upstream)` returns the gradient's colour at offset 0. It answers when
the `in` port is unwired or cannot be tapped, and a node warning says so.

### 7.4 Ports

| # | Name | Type | Unwired |
|---|---|---|---|
| 0 | `in` | HEIGHT | nothing to tap, so the uniform fallback applies |

`color_field_port()` returns 0. The window has no driven FLOAT ports: a sideband node is resolved outside
the program, so a driven param would have to be tapped separately. Omitting the ports is more honest than
adding ports that behave differently from every other node's.

### 7.5 Phase 4 gate — `GraphColorRampGate`

| Id | Criterion | Control that must fail |
|---|---|---|
| CR-A | `color_ramp_cells` vs `Gradient.sample`, 3 modes × 3 colour spaces × 3 repeats, 4097 t, RGBA within 1e-5 (CUBIC / OKLAB 1e-4) | A 256-LUT copy fails CONSTANT at a band edge |
| CR-B | Equal-offset tie agrees with VR-C, through the **same** fixture gradient | — |
| CR-C | **Paints the colour map:** height field → Color Ramp → Color Sink writes the expected sRGB per cell, read back from terrain colour data | A Const Color into the same sink must fail the per-cell comparison |
| CR-D | Color Ramp and Value Ramp (channel RED) agree per cell on the same gradient and field | — |
| CR-E | **Native route kept:** a graph with a Color Ramp → Color Sink branch plus a height branch reports `native_supported() == true` | A graph with a genuinely unlowerable node must report false, so the check is live |
| CR-F | `color_field_port` contract: Color Blend's existing gate passes unchanged, and a Color Ramp's `in` is the port tapped | A Color Ramp returning port −1 falls back to uniform and fails CR-C |
| CR-G | Wiring regression: `Color Ramp.color` → a HEIGHT input is refused by the editor's connection table (asserted headless on `is_valid_connection_type`) | *Amended:* HEIGHT → MASK, a pair the table registers, must read as accepted. COLOR → COLOR cannot be the control: GraphEdit allows same-type wires without registering them, so `is_valid_connection_type` answers false for it either way |
| CR-H | An in-place `gradient.set_color` repaints on the next bake | — |
| CR-I | Completion count ≥ 8 | — |

---

## 8. Oracle rules (read before writing any gate)

* `evaluate()` takes the native route. Oracles call `eval_cell`, `Gradient.sample` or
  `Pasture3DGraphDistance` directly.
* Every criterion has a control that must fail. Gates count completions.
* Assert on what the system produced (the exported, painted or baked result), not on your own call into
  the node.
* Threaded parity needs at least 128 rows. Sweeps use 257×257.
* **No benchmarks** in these gates. Ask before any performance measurement.

## 9. Phases

| Phase | Content | Done when |
|---|---|---|
| 1 | Shared distance metric and repeat function in all three evaluators; Falloff ported | DM gate. The baseline is captured **before** any code change |
| 2a | **GPU LUT binding and Curve GPU mode.** A generic per-step float side buffer in `pasture_3d_graph_gpu.cpp` carrying the lowered `lut`. `GKM_CURVE` for the Curve node on it | A Curve GPU gate: native vs direct GPU within 1e-4, route checked, with a control that forces the CPU route and must report it |
| 2b | **LUT audit.** Check every node that lowers or samples a `Curve` for a GPU mode, and move each that would benefit onto the 2a binding **before** any new C++ work in Phase 3. Starting list, from `sample_baked` / `"lut"` in `graph/`: **Const Curve, Path Carve, Leveler (falloff), Path Width, Path Width Field, Strata (terrace profile)**. For each, record in this spec: already GPU / moved to GPU / not worth it (with the reason, e.g. a PATH-domain node whose cost is not the kernel). An entry with no recorded reason is not done | Every listed node has a recorded outcome, and every node moved has a parity criterion added to its existing gate |
| 2c | Gradient node: oracle, native op 62, GPU mode, host placement | GR gate |

### 9.1 Phase 2b audit outcome (2026-09-14)

| Node | Outcome | Reason / evidence |
|---|---|---|
| Curve | **Moved to GPU** (2a) | `GKM_CURVE`; `GraphCurveGpuGate` |
| Const Curve | **Already GPU** (via 2a) | Registered as `GRAPH_OP_CURVE` with no inputs, so `GKM_CURVE` serves it. It has no parity criterion of its own: its lowering is Curve's with a fixed identity window. |
| Path Carve | **Already GPU**, moved onto the 2a helper | `lut_buf_of()` replaces its private upload; `carveRamp` keeps its sampler, because an empty table means smoothstep there. `PathCarveGpuGate` passes. |
| Leveler (falloff) | **Already GPU, not moved** | The apply pass binds `c` to the distance field, so the falloff LUT has to travel in the geometry buffer beside the loop. Moving it would need a sixth binding for no gain. `LevelerGpuGate` passes. |
| Path Width | **Not worth it** | A PATH-domain node registered as `GRAPH_OP_CONST`: `along` is sampled per vertex in `path_width_solve` on the host. There is no grid kernel to move, and the cost is per vertex, not per cell. |
| Path Width Field | **Not worth it** | As Path Width: `response` is sampled per vertex in `path_width_field_solve`. It reads a grid but writes a path. |
| Strata (terrace profile) | **Moved to GPU, and a bug fixed** | `native_lower()` never lowered `terrace_profile`. A custom profile shaped `eval_cell` and was silently ignored by the native kernel, which is the route the editor bakes through. The profile is now lowered as a 256-entry LUT and read by `strata_grid`, and there is a new `GKM_STRATA = 36` with the break noise filled on the host. New criterion: `GraphReliefNodeGate` H2. Native matches `eval_cell` within 5e-3 m (worst 1.4e-3); GPU matches native within 1e-3 m (worst 1.4e-4). The controls: the profile moves the result by 6.3 m, which the old native route would have failed. |
| 3 | Ramp core (§5) + Value Ramp: oracle, native op 63, GPU mode | VR gate |
| 4 | Color Ramp: `color_field_port` contract, `color_ramp_cells` native helper, node | CR gate |
| 5 | Palette entries, `[Dev/GD]` dev-flag split, preset gradients (earth tones, snowline, slope bands) as `.tres` under `addons/pasture_3d/graph/presets/` | Nodes visible with the dev flag off; presets load in both ramps |

## 10. Files touched

| File | Change |
|---|---|
| `src/pasture_3d_distance_metric.h` | **new**: metric and repeat |
| `src/pasture_3d_ramp_eval.h` | **new**: stop evaluation and colour spaces |
| `src/pasture_3d_math_ops.h/.cpp` | `falloff_grid` ported; new `gradient_grid`, `value_ramp_grid` |
| `src/pasture_3d_graph_ops.h/.cpp` | `GRAPH_OP_GRADIENT = 62`, `GRAPH_OP_VALUE_RAMP = 63`, dispatch cases |
| `src/pasture_3d_util.cpp` | `graph_op_ids()` entries; bound `color_ramp_cells` |
| `src/pasture_3d_graph_gpu.cpp` | LUT side buffer; `GRAPH_DISTANCE_METRIC_GLSL`, `GRAPH_RAMP_EVAL_GLSL`; `GKM_FALLOFF` ported; `GKM_CURVE`, `GKM_GRADIENT`, `GKM_VALUE_RAMP`; Phase 2b modes |
| `.../graph/pasture3d_graph_distance.gd` | **new** |
| `.../graph/pasture3d_graph_node.gd` | `color_field_port()` base, forwarding to `color_mask_port()`; `set_host_placement()` base no-op |
| `.../graph/pasture3d_graph_sources.gd` | `resolve` stamps host placement |
| `.../src/graph_channel_sinks.gd` | `_color_of` calls `color_field_port()` |
| `.../graph/pasture3d_graph_node_falloff.gd` | `attenuation` via `Pasture3DGraphDistance` |
| `.../graph/pasture3d_graph_node_gradient.gd`, `..._value_ramp.gd`, `..._color_ramp.gd` | **new** |
| `.../graph/pasture3d_graph_node_dev_gradient.gd`, `..._dev_value_ramp.gd`, `..._dev_color_ramp.gd` | **new**: `[Dev/GD]` |
| Phase 2b nodes | as the audit decides |
| `project/bench/GraphDistanceMetricGate.gd`, `GraphCurveGpuGate.gd`, `GraphGradientGate.gd`, `GraphValueRampGate.gd`, `GraphColorRampGate.gd` | **new** |

## 11. Deliberately not in this spec

* **Viewport gizmos** for `start` / `end`.
* **Host-space Falloff.** Falloff stays world-space. Adding `space` to it is a small follow-up once §4.3
  exists, but it changes the meaning of saved graphs, so it needs its own decision.
* **A 2D ramp** (height × slope). Two ramps combined through Color Blend cover the common case.
* **Pick-stops-from-image.**
* **RGBA program buffers.** The split made them unnecessary: scalars take the native route, and colour
  takes the sideband.
* **Driven window ports on Color Ramp** (§7.4).
* **Replacing Falloff with Gradient + Blend.** The two share math, not role.
