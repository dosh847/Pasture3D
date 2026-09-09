# Pasture3D Path Drape Remediation Specification

**Document:** `PASTURE3D_PATH_DRAPE_REMEDIATION_SPEC.md`  
**Status:** **READY FOR IMPLEMENTATION** — Derived from code review and architecture alignment (2026-09-09).  
**Scope:**  
- `project/addons/pasture_3d/graph/pasture3d_graph_node_path_drape.gd`  
- `project/addons/pasture_3d/graph/pasture3d_graph_node_path_derive.gd`  
- `project/addons/pasture_3d/src/graph_editor.gd`  
- `project/bench/PathDeriveGate.gd`  
**References:**  
- `PASTURE3D_SPLINE_GRAPH_SPEC.md` (§7.5 The Derive Family, §7.8 What S7a Built Differently, §8.4 Staged Compile S7b)  
- `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` (§4 Adding a Node, §7 Invalidation and Caching, §9 Sockets & Inline Controls, §11 Historical Defect Register)  
- `PASTURE3D_GRAPH_PORT_TYPES_GUIDE.md` (§1–6 Port Typing, Value vs Field Split, Unwired Defaults)  
- `PASTURE3D_GRAPH_VISUALIZATION_SPEC.md` (§4.3 Black Thumbnail Trap, §6.2–6.3 Viewport Path Overlay & `derived_path()`)  
- `PASTURE3D_PATH_RESHAPE_REMEDIATION_SPEC.md` (Setter Notification Contracts, Closed Ring Topology)  
- `PASTURE3D_NODE_VOCABULARY.md` (§1 Cell/Grid Split & Non-finite Semantics)  

---

## 1. Context & Motivation

The `GRID → PATH` derive family introduced in S7a ([`PASTURE3D_SPLINE_GRAPH_SPEC.md §7.5`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/PASTURE3D_SPLINE_GRAPH_SPEC.md#L683))—consisting of `Path Drape`, `Path Width from Field`, and `Path from Flow`—inverts the graph's traditional execution pipeline. Rather than generating or modifying raster heightfields from upstream geometry, these nodes sample an evaluated terrain field to synthesize or rewrite polyline geometry (`Pasture3DGraphPath`). In S7b ([`PASTURE3D_SPLINE_GRAPH_SPEC.md §8.4`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/PASTURE3D_SPLINE_GRAPH_SPEC.md#L894)), a staged compile cuts the DAG at the derive node, evaluates the upstream terrain grid, executes `eval_path()` host-side, binds the produced path into the geometry table (`geom`), and lowers the remainder of the graph to native C++/GPU execution with the derive node mapped to `GRAPH_OP_CONST` (`src/pasture_3d_util.cpp:1217`).

A comprehensive code review of [`Pasture3DGraphNodePathDrape`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/graph/pasture3d_graph_node_path_drape.gd) and its base class [`Pasture3DGraphNodePathDerive`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/graph/pasture3d_graph_node_path_derive.gd) revealed several critical algorithmic flaws, contract violations, and diagnostic gaps:

1. **Domain Boundary Clamping in `sample_grid()` Disables Out-of-Bounds Fallback:**  
   `Pasture3DGraphNodePathDrape.derive` explicitly attempts to preserve authored vertex heights when a path extends beyond the terrain extent:
   ```gdscript
   var h: float = sample_grid(surf, pts[i].x, pts[i].y)
   if not is_finite(h):
       h = p_out.heights[i] if i < p_out.heights.size() else 0.0
   ```
   However, `Pasture3DGraphNodePathDerive.sample_grid` unconditionally clamps cell indices using `clampi(x0, 0, _gw - 1)` without verifying if `(p_wx, p_wz)` lies within `_rect`. Consequently, `sample_grid()` **never returns `NAN` for out-of-domain coordinates**, returning the clamped border elevation instead. The fallback is dead code, and external paths are distorted into flat boundary shelves.
2. **Stale Road Profile Contradiction (`alignment` Retention):**  
   Base class `Pasture3DGraphNodePathDerive._derive_path` unconditionally copies `_out.alignment = src.alignment`, assuming derive nodes never move the line. While valid for `Path Width from Field` (which only modulates widths), `Path Drape` **fundamentally replaces the vertical profile (`heights`)**. A road path passing through `Path Drape` emerges with draped `heights` but retains its pre-draped `alignment` (`grade_z`). Downstream solvers like `RoadGrade` grade to `alignment`, completely ignoring the drape.
3. **Catastrophic Monotonic Seam Cliff on Closed Rings (`force_downhill`):**  
   When `force_downhill` is enabled on a closed loop (`p_out.closed == true`, such as a pond perimeter, crater rim, or closed barrier), each vertex is forced to be lower than the previous one: $h_i \le h_{i-1} - \text{min\_drop} \times \Delta s$. At the closing seam between $P_{N-1}$ and $P_0$, the path jumps vertically back up to $h_0$, creating an artificial vertical step discontinuity. `Path Drape` does not guard against or warn about closed paths.
4. **Cascading NaN Poisoning in `force_downhill`:**  
   If an incoming path contains a non-finite height, `h` falls back to `p_out.heights[i]` without an `is_finite()` guard. Because IEEE-754 / GDScript `minf(a, NAN)` evaluates to `NAN`, a single NaN at vertex 0 cascades through the sequential loop, corrupting all subsequent vertices in the polyline.
5. **Setter Contract Violations:**  
   Export setters in `Pasture3DGraphNodePathDrape` call `emit_changed()` directly instead of the mandatory `_param_changed()` hook specified in `PASTURE3D_TERRAIN_GRAPH_GUIDE.md §4.1` and `PASTURE3D_PATH_RESHAPE_REMEDIATION_SPEC.md §2 (D7)`.
6. **Missing Diagnostics Promised in Header:**  
   The file header documents that `node_warnings()` catches: (a) drapes without a downstream carve/consumer, and (b) paths drawn backwards/uphill (vertex 0 downstream of vertex $N-1$). Neither check was implemented. Furthermore, guarding the unwired warning behind `if _gw > 0` suppresses warnings when the node is freshly added to the canvas before the first bake.

---

## 2. Architectural Decisions

| # | Topic | Decision |
|---|---|---|
| **D1** | Strict Domain Bounds in `sample_grid()` | `sample_grid()` must explicitly test if `(p_wx, p_wz)` falls within `_rect` (with standard floating-point tolerance). Outside `_rect`, it must return `NAN` per its docstring, allowing `PathDrape`'s fallback to preserve authored elevations. |
| **D2** | Clear Stale `alignment` on Elevation Mutation | Because `PathDrape` replaces the vertical profile of the line, `derive` must set `p_out.alignment = null` and clear the alignment sample arrays (`sample_half_widths`, `sample_shoulders`, `sample_verges`, `sample_suppress`, `sample_skip`). Downstream nodes must grade to the draped path rather than a stale vertical solve. |
| **D3** | Closed Ring Downhill Suppression | When `p_out.closed == true`, `force_downhill` must be bypassed during execution, and `node_warnings()` must actively warn the user that closed loops cannot be monotonically non-increasing. |
| **D4** | Finite Sanitization on Fallback Heights | If `sample_grid()` returns non-finite, the fallback to `p_out.heights[i]` must verify `is_finite(p_out.heights[i])`, defaulting to `0.0` if non-finite, preventing NaN propagation through `force_downhill`. |
| **D5** | Setter Notification Standardization | Standardize all exported property setters (`offset`, `force_downhill`, `min_drop`) to call `_param_changed()`. |
| **D6** | Actionable Diagnostics in `node_warnings()` | Remove the `_gw > 0` latch on the unwired surface warning; add warnings for closed rings with `force_downhill`; add detection for paths drawn uphill from valley to hill when `force_downhill` is active. |
| **D7** | Gate Verification Expansion | Extend [`PathDeriveGate.gd`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/bench/PathDeriveGate.gd) with criteria testing out-of-domain height preservation, closed ring suppression, alignment invalidation, and diagnostic warnings. |

---

## 3. Detailed Technical Specification

### Phase 1: Base Class Domain Bounds Checking (`Pasture3DGraphNodePathDerive`)

**File:** `project/addons/pasture_3d/graph/pasture3d_graph_node_path_derive.gd`

#### 1.1 Strict Domain Testing in `sample_grid`
Update `sample_grid()` to return `NAN` when the query point is outside the captured world-space domain `_rect`:

```gdscript
func sample_grid(p_grid: PackedFloat32Array, p_wx: float, p_wz: float) -> float:
	if _gw <= 0 or _gh <= 0 or p_grid.size() < _gw * _gh:
		return NAN
	var dx: float = _rect.size.x / float(_gw)
	var dz: float = _rect.size.y / float(_gh)
	if dx <= 0.0 or dz <= 0.0:
		return NAN

	# Guard domain bounds strictly: return NAN outside the captured rectangle per the method contract.
	if p_wx < _rect.position.x or p_wx > _rect.position.x + _rect.size.x \
			or p_wz < _rect.position.y or p_wz > _rect.position.y + _rect.size.y:
		return NAN

	var fx: float = (p_wx - (_rect.position.x + 0.5 * dx)) / dx
	var fz: float = (p_wz - (_rect.position.y + 0.5 * dz)) / dz
	var x0 := int(floor(fx))
	var z0 := int(floor(fz))
	var tx: float = fx - float(x0)
	var tz: float = fz - float(z0)
	var x1 := x0 + 1
	var z1 := z0 + 1
	x0 = clampi(x0, 0, _gw - 1)
	x1 = clampi(x1, 0, _gw - 1)
	z0 = clampi(z0, 0, _gh - 1)
	z1 = clampi(z1, 0, _gh - 1)
	var v00: float = p_grid[z0 * _gw + x0]
	var v10: float = p_grid[z0 * _gw + x1]
	var v01: float = p_grid[z1 * _gw + x0]
	var v11: float = p_grid[z1 * _gw + x1]
	if not (is_finite(v00) and is_finite(v10) and is_finite(v01) and is_finite(v11)):
		return NAN
	return lerpf(lerpf(v00, v10, tx), lerpf(v01, v11, tx), tz)
```

---

### Phase 2: `PathDrape` Node Remediation (`Pasture3DGraphNodePathDrape`)

**File:** `project/addons/pasture_3d/graph/pasture3d_graph_node_path_drape.gd`

#### 2.1 Standardize Property Setters
Replace all direct calls to `emit_changed()` with `_param_changed()`:

```gdscript
@export_range(-200.0, 200.0, 0.1, "or_greater", "or_less", "suffix:m") var offset: float = 0.0:
	set(v):
		offset = v
		_param_changed()

@export var force_downhill: bool = false:
	set(v):
		force_downhill = v
		_param_changed()

@export_range(0.0, 0.5, 0.0001, "or_greater", "suffix:m/m") var min_drop: float = 0.001:
	set(v):
		min_drop = maxf(v, 0.0)
		_param_changed()
```

#### 2.2 Clear Contradictory `alignment` and Grading Metadata
In `derive()`, unconditionally clear the road alignment profile and sample arrays from `p_out`. A draped path has had its vertical profile rewritten by the terrain; preserving a pre-draped `Pasture3DRoadAlignment` creates conflicting vertical data:

```gdscript
p_out.alignment = null
p_out.sample_half_widths = PackedFloat32Array()
p_out.sample_shoulders = PackedFloat32Array()
p_out.sample_verges = PackedFloat32Array()
p_out.sample_suppress = PackedByteArray()
p_out.sample_skip = PackedByteArray()
```

#### 2.3 Finite Height Fallback & Closed Ring Downhill Handling
1. Check `is_finite()` on fallback heights.
2. Only run `force_downhill` when `not p_out.closed`.

```gdscript
func derive(_p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	p_out.alignment = null
	p_out.sample_half_widths = PackedFloat32Array()
	p_out.sample_shoulders = PackedFloat32Array()
	p_out.sample_verges = PackedFloat32Array()
	p_out.sample_suppress = PackedByteArray()
	p_out.sample_skip = PackedByteArray()

	if port_unwired(1):
		return
	var surf: PackedFloat32Array = _grids[1]
	var pts := p_out.points
	var n := pts.size()
	var hs := PackedFloat32Array()
	hs.resize(n)
	for i in n:
		var h: float = sample_grid(surf, pts[i].x, pts[i].y)
		if not is_finite(h):
			var prev_h: float = p_out.heights[i] if i < p_out.heights.size() else 0.0
			h = prev_h if is_finite(prev_h) else 0.0
		hs[i] = h + offset

	# Closed paths cannot be monotonically downhill without inducing a seam step cliff; suppress when closed.
	if force_downhill and n > 1 and not p_out.closed:
		for i in range(1, n):
			var run: float = pts[i].distance_to(pts[i - 1])
			hs[i] = minf(hs[i], hs[i - 1] - min_drop * run)
	p_out.heights = hs
```

#### 2.4 Complete Diagnostic Warnings in `node_warnings()`
Implement diagnostic checks to fulfill the contract described in the header documentation:

```gdscript
func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	# Unwired surface: report unconditionally without waiting for _gw > 0.
	if port_unwired(1):
		out.append("Path Drape has no surface wired, so it passes the path through unchanged. Wire the "
				+ "terrain you want it to sit on into `surface`.")
	if force_downhill:
		if _out != null and _out.closed:
			out.append("Path is closed: Force Downhill is suppressed because a closed loop cannot be "
					+ "monotonically downhill without creating a vertical cliff at the seam.")
		elif _out != null and _out.points.size() >= 2 and _grids.size() > 1 and not _grids[1].is_empty():
			var h0: float = sample_grid(_grids[1], _out.points[0].x, _out.points[0].y)
			var h_end: float = sample_grid(_grids[1], _out.points[-1].x, _out.points[-1].y)
			if is_finite(h0) and is_finite(h_end) and h_end > h0 + 5.0:
				out.append("The terrain rises along this path from vertex 0 to the end. Force Downhill "
						+ "clamps from vertex 0, which will carve deeply into the terrain. Reverse the spline "
						+ "so vertex 0 sits at the upstream head.")
	return out
```

---

### Phase 3: Gate Expansion & Verification (`PathDeriveGate.gd`)

**File:** `project/bench/PathDeriveGate.gd`

Extend `CRITERIA` with four new assertions: `["G", "H", "I", "J"]`.

#### 3.1 Criterion `[G]`: Out-of-Domain Vertices Preserve Authored Heights
- **Fixture:** Construct a path with 5 vertices where vertices 0–2 sit inside `RECT` and vertices 3–4 sit outside `RECT` with an authored elevation of `50.0 m`.
- **Assertion:** Evaluate graph through `PathDrape`. Verify that vertices 0–2 equal `sample_grid(surf, ...)` while vertices 3–4 retain their authored `50.0 m` (+ `offset`).
- **Control:** Verify that within domain bounds, heights match the sampled surface and differ from the authored height.

#### 3.2 Criterion `[H]`: Closed Rings Suppress `force_downhill` Seam Step
- **Fixture:** Construct a closed circular loop on a rising surface with `force_downhill = true`.
- **Assertion:** Verify that the difference $|hs[N-1] - hs[0]|$ equals the terrain surface difference between those points, proving that sequential downhill clamping was suppressed.
- **Control:** Run the exact same points with `closed = false`; verify that $hs[N-1]$ is clamped significantly below $hs[0]$.

#### 3.3 Criterion `[I]`: Stale Road `alignment` is Cleared by `PathDrape`
- **Fixture:** Inject a `Pasture3DGraphPath` with a non-null `alignment` into `PathDrape`.
- **Assertion:** Verify that `derived_path().alignment == null` and `sample_half_widths.is_empty()`.
- **Control:** Run the same path through `PathWidthField`; verify that `derived_path().alignment != null` (Path Width retains alignment).

#### 3.4 Criterion `[J]`: Diagnostic Warnings Fire Accurately
- **Assertions:**
  1. `PathDrape` with unwired surface returns warning immediately.
  2. Closed path with `force_downhill = true` emits the closed loop warning.
  3. Uphill line on rising terrain fixture with `force_downhill = true` emits the upstream direction warning.
- **Control:** Healthy downhill open path emits zero warnings.

---

## 4. Implementation Checklist

- [ ] **Phase 1: `Pasture3DGraphNodePathDerive`**
  - [ ] Add strict domain checking against `_rect` in `sample_grid()` (`project/addons/pasture_3d/graph/pasture3d_graph_node_path_derive.gd`).
- [ ] **Phase 2: `Pasture3DGraphNodePathDrape`**
  - [ ] Convert `@export` property setters (`offset`, `force_downhill`, `min_drop`) to call `_param_changed()`.
  - [ ] Reset `p_out.alignment = null` and clear grading sample arrays in `derive()`.
  - [ ] Guard fallback height against non-finite values in `derive()`.
  - [ ] Suppress `force_downhill` when `p_out.closed == true`.
  - [ ] Expand `node_warnings()` to detect unwired surface, closed loops with downhill clamp, and uphill drawn lines.
- [ ] **Phase 3: Verification & Test Gates**
  - [ ] Update `PathDeriveGate.gd` to add criteria `[G]`, `[H]`, `[I]`, and `[J]`.
  - [ ] Execute `PathDeriveGate.tscn` via headless console Godot binary; verify clean PASS.
  - [ ] Execute `PathStagedCompileGate.tscn`; verify S7b staged compile parity is maintained.
  - [ ] Execute `GraphNodeParamGate.tscn`; verify parameter invalidation sweep remains green.
