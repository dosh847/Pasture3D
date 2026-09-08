# Pasture3D Path Reshape Remediation Specification

**Document:** `PASTURE3D_PATH_RESHAPE_REMEDIATION_SPEC.md`  
**Status:** **READY FOR IMPLEMENTATION** — Derived from code review and `/grill-me` design alignment (2026-09-08).  
**Scope:**  
- `project/addons/pasture_3d/graph/pasture3d_graph_node_path_shape.gd`  
- `project/addons/pasture_3d/graph/pasture3d_graph_node_path_fractalize.gd`  
- `project/addons/pasture_3d/graph/pasture3d_graph_node_path_meanderize.gd`  
- `project/addons/pasture_3d/src/graph_editor.gd`  
- `project/bench/PathShapeGate.gd`  
**References:**  
- `PASTURE3D_SPLINE_GRAPH_SPEC.md` (§7.4 Reshape Family)  
- `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` (§4 Adding a Node, §9 Sockets & Inline Controls)  
- `PASTURE3D_NODE_ACCELERATION_GUIDE.md` (Step 0 Carve-Out for PATH Nodes)  

---

## 1. Context & Motivation

The `PATH -> PATH` reshape family introduced in S5 (`Path Resample`, `Path Smooth`, `Path Decimate`, `Path Fractalize`, `Path Meanderize`) operates host-side during the graph pre-pass over a few hundred to a few thousand polyline vertices. Because they run once per compile and lower to `GRAPH_OP_CONST` placeholders, their execution remains on the GDScript tier without violating the 3-tier acceleration contract (`blocks_native() == false`).

However, a code review of [`Pasture3DGraphNodePathFractalize`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/graph/pasture3d_graph_node_path_fractalize.gd) and [`Pasture3DGraphNodePathMeanderize`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/graph/pasture3d_graph_node_path_meanderize.gd) revealed multiple critical flaws:
1. **Dead `pin_ends` parameters:** In `PathFractalize`, midpoint displacement only inserts midpoints, so setting `pin_ends = false` produces the exact same byte-for-byte output as `true`. In `PathMeanderize`, clamping neighbor indices for endpoints creates zero-length segment vectors, hitting a premature `continue` that prevents endpoints from ever displacing when `pin_ends == false`.
2. **Catastrophic closed-loop excision:** In `PathMeanderize._cut_loops`, the excision logic unconditionally connects $p_i \to x \to p_{j+1}$. On a closed ring, if a self-intersection spans across the seam (e.g., segment 1 intersects segment $segs - 1$), this excises the entire polygon body instead of the small seam pinch, leaving a collapsed triangular remnant.
3. **Broken attribute projection across closed seams:** In base class [`Pasture3DGraphNodePathShape`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/addons/pasture_3d/graph/pasture3d_graph_node_path_shape.gd), `project_s` and `arc_lengths` only iterate open segments $1 \dots N-1$, completely omitting the closing segment $(P_{N-1}, P_0)$. Any vertex along the closing edge projects to the wrong segment, receiving incorrect arc lengths and corrupted half-widths/heights.
4. **Quadratic spatial bucket explosion:** `_cells_of` indexes the full 2D axis-aligned bounding box of a segment. On paths with non-uniform segment lengths (e.g. a long 1000 m segment alongside 2 m segments), a diagonal segment indexes $O(K^2)$ cells rather than $O(K)$.
5. **Contract violations & memory churn:** Export setters call `emit_changed()` directly instead of `_param_changed()`, and array growth via `append()` in nested loops causes continuous dynamic reallocations despite attempts to call `resize(0)`.

---

## 2. Architectural Decisions (Aligned via `/grill-me`)

| # | Topic | Decision |
|---|---|---|
| **D1** | `PathFractalize.pin_ends` | When `pin_ends == false`, actively displace the first and last endpoints along the adjacent edge's normal using `rng.randfn() * amp` (respecting `Bias` orientation). |
| **D2** | `PathMeanderize.pin_ends` | When `pin_ends == false`, displace unpinned endpoints perpendicular to their single adjacent segment using noise jitter (`nrm * chord * noise_ratio * jitter`) with zero curvature turn ($turn = 0.0$). |
| **D3** | `_cut_loops` on Closed Rings | Compute segment counts / arc lengths of both candidate loops (forward sub-path from $i$ to $j$ vs wrap-around sub-path from $j$ to $i$ through the seam) and excise the shorter path, preserving the main polygon body. |
| **D4** | Spatial Grid Traversal | Replace `_cells_of` axis-aligned bounding-box iteration with a 2D line-grid traversal (DDA / supercover raycast) so segments only index the cells they physically cross ($O(K)$). |
| **D5** | Base Closed Seam Projection | Extend `carry_values` and `project_s` to include the closing segment $(P_{N-1}, P_0)$ when `p_src.closed == true`, properly wrapping arc lengths and interpolating attributes across the seam. |
| **D6** | Editor Inline Controls | Add a seed re-roll button (🎲) to `graph_editor.gd::_add_inline_node_controls` for `path_fractalize` and `path_meanderize`. |
| **D7** | Setter Notifications | Standardize all setters to call `_param_changed()` per `PASTURE3D_TERRAIN_GRAPH_GUIDE.md §4.1`. |
| **D8** | Gate Test Coverage | Extend [`PathShapeGate.gd`](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/project/bench/PathShapeGate.gd) with explicit criteria for unpinned endpoints (`pin_ends = false`), closed ring loop excision across the seam, and closed seam attribute projection. |

---

## 3. Detailed Technical Specification

### Phase 1: Shared Base Class Remediation (`Pasture3DGraphNodePathShape`)

**File:** `project/addons/pasture_3d/graph/pasture3d_graph_node_path_shape.gd`

#### 1.1 Closed-Aware `arc_lengths`
`arc_lengths` must calculate the cumulative distance along the full polyline, including the closing segment when closed:
```gdscript
static func arc_lengths_ring(p_pts: PackedVector2Array, p_closed: bool) -> PackedFloat32Array:
	var n := p_pts.size()
	var count := n + 1 if (p_closed and n >= 2) else n
	var cum := PackedFloat32Array()
	cum.resize(count)
	if count == 0:
		return cum
	cum[0] = 0.0
	for i in range(1, n):
		cum[i] = cum[i - 1] + p_pts[i].distance_to(p_pts[i - 1])
	if p_closed and n >= 2:
		cum[n] = cum[n - 1] + p_pts[0].distance_to(p_pts[n - 1])
	return cum
```

#### 1.2 Closed-Aware `project_s`
Update `project_s` to test all segments: $N-1$ segments for open paths, and $N$ segments for closed paths:
```gdscript
static func project_s_closed(p_pts: PackedVector2Array, p_cum: PackedFloat32Array, p_q: Vector2, p_closed: bool) -> float:
	var best := INF
	var best_s := 0.0
	var n := p_pts.size()
	var seg_count := n if (p_closed and n >= 2) else (n - 1)
	for i in seg_count:
		var a := p_pts[i]
		var b := p_pts[(i + 1) % n]
		var ab := b - a
		var len2 := ab.length_squared()
		var t: float = 0.0 if len2 <= 0.0 else clampf((p_q - a).dot(ab) / len2, 0.0, 1.0)
		var d: float = p_q.distance_squared_to(a + ab * t)
		if d < best:
			best = d
			var s0: float = p_cum[i]
			var s1: float = p_cum[i + 1]
			best_s = s0 + (s1 - s0) * t
	return best_s
```

#### 1.3 Closed-Aware `sample_along`
When sampling across the closing edge ($s \in [cum[n-1], cum[n]]$), linearly interpolate between $vals[n-1]$ and $vals[0]$:
```gdscript
static func sample_along_closed(p_vals: PackedFloat32Array, p_cum: PackedFloat32Array, p_s: float, p_closed: bool) -> float:
	var n := p_vals.size()
	if n == 0:
		return NAN
	if n == 1 or p_cum.size() < 2:
		return p_vals[0]
	var last_s: float = p_cum[p_cum.size() - 1]
	if p_s <= 0.0 or last_s <= 0.0:
		return p_vals[0]
	if p_s >= last_s:
		return p_vals[0] if p_closed else p_vals[n - 1]

	var i := 1
	while i < p_cum.size() - 1 and p_cum[i] < p_s:
		i += 1
	var s0: float = p_cum[i - 1]
	var s1: float = p_cum[i]
	var t: float = 0.0 if s1 <= s0 else (p_s - s0) / (s1 - s0)
	var idx0 := (i - 1) % n
	var idx1 := i % n
	return lerpf(p_vals[idx0], p_vals[idx1], t)
```

#### 1.4 Update `carry_values`
In `carry_values`, switch to `arc_lengths_ring`, `project_s_closed`, and `sample_along_closed(..., p_src.closed)`.

---

### Phase 2: `PathFractalize` Remediation

**File:** `project/addons/pasture_3d/graph/pasture3d_graph_node_path_fractalize.gd`

#### 2.1 Setters
Replace all direct calls to `emit_changed()` with `_param_changed()`.

#### 2.2 Endpoint Displacement when `pin_ends == false`
During each iteration, if `not pin_ends and not p_src.closed`:
- Displace the start point along the normal of the first segment $(pts[1] - pts[0])$.
- Displace the end point along the normal of the last segment $(pts[last] - pts[last - 1])$.
- Apply the same `Bias` orientation and random draw from the shared `rng` generator.
- Displace by `amp` scaled by noise.

To maintain RNG stream determinism:
- The random draws for endpoint displacement must be taken deterministically at the start and end of the loop pass.

#### 2.3 Deterministic Array Pre-Allocation
Replace `next.resize(0)` with exact pre-allocation:
```gdscript
var n_pts := pts.size()
var target_size := (n_pts - 1) * 2 + 1
var next := PackedVector2Array()
next.resize(target_size)
var out_idx := 0

for i in range(n_pts - 1):
	var a := pts[i]
	var b := pts[i + 1]
	...
	next[out_idx] = a
	out_idx += 1
	next[out_idx] = mid + nrm * (d * amp)
	out_idx += 1

next[out_idx] = pts[n_pts - 1]
```

---

### Phase 3: `PathMeanderize` Remediation

**File:** `project/addons/pasture_3d/graph/pasture3d_graph_node_path_meanderize.gd`

#### 3.1 Setters
Replace all direct calls to `emit_changed()` with `_param_changed()`.

#### 3.2 Unpinned Endpoints in `_amplify`
In `_amplify`:
```gdscript
if is_end and not p_closed:
	if pin_ends:
		continue
	# Endpoint displacement: curvature turn is 0.0, displace by noise along the segment normal.
	var seg := (p_pts[1] - p_pts[0]) if i == 0 else (p_pts[n - 1] - p_pts[n - 2])
	var seg_len := seg.length()
	if seg_len > 0.0:
		var nrm := Vector2(seg.y, -seg.x) / seg_len
		out[i] = p_pts[i] + nrm * (seg_len * noise_ratio * jitter)
	continue
```

#### 3.3 Closed-Ring Seam Loop Excision in `_cut_loops`
On a closed ring, crossing segments $i$ and $j$ ($i < j$) form two loops:
1. **Forward loop:** segments $i \dots j$, with count $C_{fwd} = j - i$.
2. **Wrap-around loop:** segments $j \dots segs - 1$ plus $0 \dots i$, with count $C_{wrap} = segs - (j - i)$.

When $C_{fwd} \le C_{wrap}$:
- Excise the forward loop: keep $p_0 \dots p_i$, insert $best\_x$, jump to $j + 1$, and continue to $p_{segs}$. (Current forward behavior).

When $C_{wrap} < C_{fwd}$ (crossing spans across the seam):
- Excise the wrap-around loop: keep the vertices between $i + 1$ and $j$.
- Connect $best\_x \to p_{i+1} \dots p_j \to best\_x$.
- Close the ring by duplicating $best\_x$ at both ends.
- Terminate the loop pass immediately, as the seam has been excised.

#### 3.4 2D Supercover Line Traversal in `_cells_of`
Replace full bounding box loops with 2D supercover line traversal (Bresenham / DDA grid intersection) so segments only index the cells they physically cross:
```gdscript
static func _cells_of(p_a: Vector2, p_b: Vector2, p_cell: float) -> Array[Vector2i]:
	var x0 := int(floor(p_a.x / p_cell))
	var y0 := int(floor(p_a.y / p_cell))
	var x1 := int(floor(p_b.x / p_cell))
	var y1 := int(floor(p_b.y / p_cell))

	var dx := absi(x1 - x0)
	var dy := absi(y1 - y0)
	var sx := 1 if x1 >= x0 else -1
	var sy := 1 if y1 >= y0 else -1

	var x := x0
	var y := y0
	var err := dx - dy
	var out: Array[Vector2i] = []

	while true:
		out.append(Vector2i(x, y))
		if x == x1 and y == y1:
			break
		var e2 := 2 * err
		if e2 > -dy:
			err -= dy
			x += sx
		if e2 < dx:
			err += dx
			y += sy
	return out
```

#### 3.5 Pre-Allocation in `_subdivide`
Pre-allocate the output array deterministically:
```gdscript
var n := p_pts.size()
var target_count := (n - 1) * edge_divisions + 1
var out := PackedVector2Array()
out.resize(target_count)
var idx := 0
for i in range(n - 1):
	var a := p_pts[i]
	var b := p_pts[i + 1]
	for k in edge_divisions:
		out[idx] = a.lerp(b, float(k) / float(edge_divisions))
		idx += 1
out[idx] = p_pts[n - 1]
```

---

### Phase 4: Graph Editor Canvas Inline Controls

**File:** `project/addons/pasture_3d/src/graph_editor.gd`

In `_add_inline_node_controls(p_gn: GraphNode, p_index: int, p_node: Pasture3DGraphNode)`:
Add handling for `path_fractalize` and `path_meanderize`:
```gdscript
&"path_fractalize", &"path_meanderize":
	var row := HBoxContainer.new()
	var seed_btn := Button.new()
	seed_btn.text = "🎲"
	seed_btn.tooltip_text = "Randomize Seed"
	seed_btn.pressed.connect(func():
		p_node.set("seed", randi() % 100000)
	)
	row.add_child(seed_btn)
	p_gn.add_child(row)
```

---

### Phase 5: Verification & Gate Expansion

**File:** `project/bench/PathShapeGate.gd`

Extend `PathShapeGate` with three new criteria:

#### 5.1 Criterion `[H]`: `pin_ends = false` Actively Displaces Endpoints
- **Assertion:** Run `PathFractalize` and `PathMeanderize` with `pin_ends = false` and verify that the first and last endpoints differ from the input endpoints ($pts[0] \ne in.points[0]$ and $pts[last] \ne in.points[last]$).
- **Control:** Verify that with `pin_ends = true`, endpoints match the input exactly ($pts[0] == in.points[0]$ and $pts[last] == in.points[last]$).

#### 5.2 Criterion `[I]`: Closed Ring Loop Excision Preserves the Polygon Body
- **Assertion:** Construct a closed circular polygon with an engineered seam-crossing loop between segment 1 and segment $segs - 1$.
- **Assertion:** Run `PathMeanderize` with `remove_loops = true`.
- **Validation:** Confirm that the excised path maintains a valid polygon with vertex count $> segs / 2$ and no self-intersections, rather than collapsing to a 3-vertex triangle.

#### 5.3 Criterion `[J]`: Closed Ring Attribute Projection Covers the Closing Seam
- **Assertion:** Create a closed polygon with varying `half_widths` and `heights` along its perimeter.
- **Assertion:** Run `PathResample`, `PathFractalize`, and `PathMeanderize`.
- **Validation:** Inspect vertices located along the closing edge $(P_{N-1}, P_0)$. Confirm that their interpolated widths and heights lie strictly within $[min(w_{last}, w_0), max(w_{last}, w_0)]$ and are not NaN or projected onto distant open segments.

---

## 4. Implementation Checklist

- [ ] `pasture3d_graph_node_path_shape.gd`: Update `arc_lengths_ring`, `project_s_closed`, `sample_along_closed`, and `carry_values` for closed paths.
- [ ] `pasture3d_graph_node_path_fractalize.gd`:
  - [ ] Switch setters to `_param_changed()`.
  - [ ] Pre-allocate `next` via `resize((n - 1) * 2 + 1)`.
  - [ ] Implement endpoint displacement when `pin_ends == false`.
- [ ] `pasture3d_graph_node_path_meanderize.gd`:
  - [ ] Switch setters to `_param_changed()`.
  - [ ] Implement single-sided endpoint jitter when `pin_ends == false`.
  - [ ] Implement shorter-path loop excision in `_cut_loops` on closed rings.
  - [ ] Implement DDA supercover line traversal in `_cells_of`.
  - [ ] Pre-allocate `out` in `_subdivide`.
- [ ] `graph_editor.gd`: Add 🎲 seed re-roll button to `_add_inline_node_controls` for both nodes.
- [ ] `PathShapeGate.gd`: Add criteria `[H]`, `[I]`, and `[J]`, along with failing controls. Run and verify clean pass.
