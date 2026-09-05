# Pasture3D Terrain Graph — working guide

How the node graph is put together, what a node owes the system, and the mistakes that have actually
been made in it. This is the document that outlives `PASTURE3D_TERRAIN_GRAPH_SPEC.md`: the spec is a
build plan and finishes, this describes the thing that was built.

**Scope, so three documents do not say the same thing three ways:**

| Question | Document |
|---|---|
| What still has to be built, and in what order | `PASTURE3D_TERRAIN_GRAPH_SPEC.md` |
| How to write the C++ kernel, lower it, and benchmark it | `PASTURE3D_NODE_ACCELERATION_GUIDE.md` |
| What a node is, how the graph runs it, and what breaks | this file |
| What the op names mean, and why the graph shares them with the brush stack | `PASTURE3D_NODE_VOCABULARY.md` |

---

## 1. The pieces

| File | What it is |
|---|---|
| `graph/pasture3d_terrain_graph.gd` | The graph resource: `nodes`, `connections`, `output_node`, the evaluator, the compilers, the caches |
| `graph/pasture3d_graph_node.gd` | The base every node extends. Ports, op tag, cache, invalidation, native lowering hooks |
| `graph/pasture3d_graph_solver_node.gd` | Adds the LIVE/FROZEN protocol for nodes whose solve is expensive |
| `graph/pasture3d_graph_node_registry.gd` | The palette. An op is addable only if it has an entry here |
| `graph/pasture3d_graph_node_<op>.gd` | One node each. `dev_` prefixed twins are the pure-GDScript oracles |
| `src/graph_editor.gd` | The bottom-panel `GraphEdit`, the palette, the inline previews |
| `src/pasture_3d_graph_ops.cpp`, `src/pasture_3d_graph_gpu.cpp` | The native CPU and GPU evaluators |
| `project/bench/Graph*Gate.*` | One gate per claim. See §8 |

---

## 2. The data model

A graph is a DAG held in three exported fields:

- **`nodes: Array[Pasture3DGraphNode]`** — authoring order only. Evaluation order is derived.
- **`connections: Array`** — each entry a `PackedInt32Array` of `[from_node, from_port, to_node, to_port]`.
  Wire them with `connect_ports(from, from_port, to, to_port)`. There is no `connect_nodes`; a gate once
  called it, the call errored, and what the gate then timed was a graph with no wires in it at all.
- **`output_node: int`** — index of the node whose grid is the result. `-1` means no output, and
  `evaluate()` returns a flat 0 field rather than guessing.

### Ports and types

`PortType` is `HEIGHT, MASK, VECTOR, CURVE, FLOAT, INT, COLOR, BOOL, TERRAIN_BUS, PATH`. Types colour the
slots and validate wiring; the evaluator moves a `PackedFloat32Array` per port regardless — with one
exception.

**PATH is a sideband.** A road is a centreline and a width, not a field, and rasterising it into a grid
to send it down a wire would fix its resolution at the wire instead of at the consumer. A PATH-producing
node still occupies a grid slot filled with zeros (so no loop that indexes `grids` by node needs a
special case), and the resource travels beside the grids. A node that consumes one answers
`reads_paths()` and receives `set_path_inputs(paths)` in input-port order, immediately before
`eval_grid`.

### Multiple outputs

`output_count() > 1` is for solvers publishing derived channels next to their height — flow, sediment,
deposition mask. Port 0 goes into `grids`; ports ≥ 1 go into a parallel `aux` map. **Editor slots are
contiguous from row 0, so port index equals channel index** — that correspondence is load-bearing, not a
coincidence to preserve by accident.

---

## 3. The evaluators, and which one runs

`evaluate()` tries, in order:

1. **Native whole-graph** — `compile_graph_program()` lowered to `Pasture3DUtil.graph_eval_grid`, which
   internally picks GPU or threaded CPU by grid size.
2. **Folded GDScript** — a run of cell nodes fused into one pass.
3. **`_eval_unfolded()`** — the independent per-node oracle.

Three evaluators means **anything true of only one of them is a latent defect**. That is the whole
subject of `PASTURE3D_NODE_ACCELERATION_GUIDE.md` §3.4 and it is not repeated here. Two consequences
belong in this guide because they shape how you write a node:

- **The native bail is graph-wide.** One node answering `blocks_native()` takes the *entire* graph off
  the native path, not just itself. That is the price of a node owning state — a FROZEN cache — that a
  pure compiled program cannot serve or invalidate. It is why `evaluation` defaults to LIVE.
- **An unwired input port binds the zero buffer** on the native path. If your node treats "unwired" as
  anything other than a field of zeros, the two paths disagree and only one of them is wrong.

### Threading

`Pasture3DTerrainGraph.evaluate()` **refuses to run off the main thread** — it mutates the shared
resource on both routes (`store_cache`, access ticks, eviction), and racing that against a main-thread
edit of `nodes` surfaces as an out-of-range index or a corrupted cache grid. It pushes an error and
returns zeros, so a caller that ignores the error still gets a defined grid rather than a race.

**The supported split is compile here, solve there:**

```gdscript
var prog := graph.compile_graph_program()          # main thread
WorkerThreadPool.add_task(func():
    var z := Pasture3DUtil.graph_eval_grid(prog, gw, gh, rect, PackedFloat32Array()))  # worker
```

`Pasture3DUtil.graph_gpu_threshold()` returns **0 off the main thread**, which is how the graph declines
RenderingDevice there. Gate: `GraphWorkerThreadGate`.

---

## 4. Adding a node

### 4.1 The script

```gdscript
@tool
class_name Pasture3DGraphNodeExample
extends Pasture3DGraphNode        # or Pasture3DGraphSolverNode

@export var amplitude: float = 10.0:
    set(v):
        amplitude = v
        _param_changed()

func _init() -> void:
    super()                        # NOT OPTIONAL — see below

func op() -> StringName: return &"example"
func role() -> Role: return Role.FILTER
func needs_grid() -> bool: return false
func input_count() -> int: return 1
func input_names() -> PackedStringArray: return PackedStringArray(["height"])
func input_port_types() -> PackedInt32Array: return PackedInt32Array([PortType.HEIGHT])
func eval_cell(p_wx: float, p_wz: float, p_inputs: Array) -> float:
    return p_inputs[0] * amplitude
```

**`super()` in `_init` is not optional.** `Pasture3DGraphNode._init` connects `changed` to the revision
bump. A subclass `_init` that does not chain silently drops that connection, and *every* parameter on the
node — `muted` included — becomes invisible to invalidation: the node serves its first grid forever.
Five nodes shipped this way and `GraphNodeParamGate` reported 50 dead properties across them. It names
each one that stops bumping.

**Every setter calls `_param_changed()`.** GDScript `@export` assignment emits **no** `Resource.changed`.
A parameter that is a plain `@export` with no setter does not invalidate anything, and
`_compute_node_inputs_hash` does not read parameters either — so nothing anywhere notices the edit.

**Cell or grid.** `needs_grid() == false` gives you `eval_cell(wx, wz, inputs)`, one cell at a time, and
your node can be folded into a fused pass later. `true` gives you
`eval_grid(inputs, gw, gh, mask, rect)` and the whole field. A blur, a routing solve or anything reading
neighbours must be a grid node; everything else should not be.

### 4.2 Registering it

Add an entry to `Pasture3DGraphNodeRegistry.entries()`:

```gdscript
{"op": &"example", "title": "Example", "category": "Filters", "role": "Filter",
 "script": ExampleScript, "tags": ["…"], "description": "One line, shown in the palette."}
```

A node with no registry entry cannot be added from the editor at all. The `category` used to have to
appear in `categories()` or the palette dropped the entry without a word — Road Source and Path Distance
both shipped invisible that way — so an unlisted category is now *appended* rather than discarded. That
makes the failure a category in the wrong place instead of a node nobody can add.
Gate: `GraphPaletteAndConstantsGate`.

### 4.3 The Dev/GD twin

A `dev_` node is the pure-GDScript reference for a native op — the oracle a parity gate compares against.
Two rules:

- **The twin must RUN its oracle.** `eval_grid_channels` packs the `@export`s into the params dictionary
  and calls the node's own `static func solve_oracle(...)` through `solve_cached`; `eval_grid` returns
  channel 0. Two twins once defined neither, inherited the base `eval_grid` (which returns input 0
  unchanged), and offered the entire freeze protocol over a node that never solved.
  Gate: `GraphSolverFreezeGate [E]`.
- **Dev nodes are hidden behind a flag.** `pasture_3d/developer/enable_gdscript_reference_nodes`. Only
  the C++-backed nodes are visible by default; the GDScript version *is* the `[Dev/GD]` node, it is not
  a separate implementation to keep in step by hand.

### 4.4 Native acceleration

`native_lower()`, `native_param_ports()`, `native_out_count()` and the C++ kernel are
`PASTURE3D_NODE_ACCELERATION_GUIDE.md`, §2 for the playbook and §3 for the rules. The one thing worth
repeating here: `native_out_count()` reports what the **kernel** writes, not what the editor offers. An
op may expose five ports and implement one, and saying `output_count()` there serves a field of zeros
that looks exactly like a real answer.

---

## 5. Solver nodes and the freeze

Extend `Pasture3DGraphSolverNode` when a solve is expensive enough that re-running it on every
evaluation is not acceptable. You get `enum Evaluation { LIVE, FROZEN }`, a Bake button, a stale
warning, and:

```gdscript
func eval_grid_channels(p_inputs, p_gw, p_gh, _p_mask, p_rect) -> Array:
    var surface: PackedFloat32Array = …
    return solve_cached(solver_cache_key(p_gw, p_gh, [surface, mask_in]),
            func(): return _solve(surface, p_gw, p_gh, p_rect))
```

- **`solver_cache_key(gw, gh, grids)` is the only way to build the key.** Twenty solvers used to spell it
  four ways; two of them omitted `gw`/`gh` entirely, so a frozen Lake Flooding could not tell 512×128
  from 128×512 — same cell count, same values, same key — and served a lake surface against a grid of a
  different shape. *Which* grids are dependencies is still each node's business; turning them into a key
  is not.
- **`_param_changed()` must also `mark_dirty_since_bake()`**, or a frozen solve stops matching its
  parameters without saying so.
- **Override `_clear_solver_cache()`, never `clear_cache()`.** All twenty solvers once overrode the
  latter without calling `super`, so eviction freed zero measured bytes, the eviction loop walked the
  whole graph, and each override's `emit_changed()` destroyed the frozen solve the freeze exists to keep.
- **LIVE must keep answering `blocks_native() == false`**, or freezing one node would cost native
  everywhere.

---

## 6. Invalidation and caching

Three signals, and they are not interchangeable:

| Signal | Meaning | Who listens |
|---|---|---|
| `changed` | The **baked result** would differ | Host brush / modifier; `_bump_revision` |
| `node_changed(index)` | Some node's parameters changed, whatever it is wired to | The editor, for preview refreshes |
| `structure_changed` | Topology moved: nodes, wires, output, frames | Topology caches, the editor canvas |

`changed` is filtered: a node's `changed` is re-emitted by the graph only when that node **feeds the
active output**, so tuning a disconnected branch does not re-bake the terrain. Two things about that
filter are worth knowing, because both were once wrong:

- A graph with **no output selected** — the normal state while one is being authored — has nothing for an
  edit to be downstream of and nothing baked for a re-bake to cost. It counts as affecting the output;
  treating it as "irrelevant" froze `_revision`, and every cache keyed on `content_key()` with it.
- The editor's inline previews render nodes the bake filter excludes, which is exactly what previews are
  for. That is why `node_changed` exists as a second signal rather than the filter being widened.

`content_key()` is the host's staleness key: a monotonic revision, bumped on every `changed`. Absolute
value does not matter, only that it moves.

**What not to memoise.** `native_supported()` is memoised on `[root, revision]` because it derives a
*bool* from structure. `compile_graph_program()`'s result is deliberately **not** memoised: a compiled
program copies node values into flat arrays, and caching those bytes means a source that mutates without
announcing it leaves the program silently stale. That failure has been paid for once already.
Generally: **cache on the output, not the input** — a road's paint depends on the ground, so keying its
skip on the road's own properties ships a stale paint.

---

## 7. The editor

- **Previews are owned by the editor, not the node.** One low-resolution multi-tap evaluation fills every
  open thumbnail at once, off the main thread, debounced. `evaluate()` never renders a thumbnail, and
  toggling a preview is a pure show/hide of an already-built `TextureRect`. The node stores nothing but
  the `preview_on` flag.
- **`graph_position` deliberately emits no `changed`.** Dragging a node is a reason to re-save the
  layout, not to re-bake the terrain. `GraphEditModelGate [E]`'s control asserts exactly this.
- **A dynamic inspector hint needs `notify_property_list_changed()`.** Without it the hint is invisible,
  and reading the hint back in a test cannot detect that.
- **Scene-naming sources resolve host-side.** A node that names a scene object (a road, a shape) does not
  reach out for it; one entry point on the host fills every such source. Three call sites used to each
  call the road resolver themselves.

---

## 8. Gates

One gate per claim, and the graph family is dense enough that the right first question about a change is
*which gate owns this*:

| Gate | Owns |
|---|---|
| `GraphEditModelGate` | The mutation API: add / connect / set_output / remove, and signal forwarding |
| `GraphNodeParamGate` | Every exported property on every node invalidates |
| `GraphSolverFreezeGate` | One freeze protocol, declared once, and every solver has a solve to freeze |
| `GraphNodeCachingGate` | The per-node buffer cache and eviction |
| `GraphCppParityGate`, `GraphGpuParityGate` | Native and GPU agree with the oracle (GPU: **windowed**) |
| `GraphDevTwinGate` | Each `dev_` twin matches its production node |
| `GraphFoldGate` | The folded path equals the unfolded one |
| `GraphWorkerThreadGate` | The threading contract of §3 |
| `GraphNodeEditorUIGate`, `GraphPaletteAndConstantsGate` | Every registered node is addable and evaluable |
| `GraphAllNodeSocketsGate`, `GraphOpVocabularyGate` | Ports and op names stay consistent |

Discipline for writing one is in `PASTURE3D_NODE_ACCELERATION_GUIDE.md` §3.4 and §3.8. The four that
bite hardest in this area:

- **Every criterion needs a control that fails.** A criterion that cannot go red is not a criterion.
- **A gate must tell "measured nothing" from "measured well."** Read a flag between the stimulus and the
  remedy, never after.
- **Sweep the registry, not a list of names**, so a node written next month is covered the day it appears.
- **Never widen a threshold to clear a red gate.** Fix the evaluator.

Headless notes: GPU gates need a window (no local RenderingDevice headless) and must report NO-SIGNAL
rather than pass; `_schedule_refresh` is editor-only, so a headless gate asserts the returned decision,
not `_full_dirty`; and a gate that touches `data_directory` can modify the demo data, so a clean
`git status` after a gate run proves nothing about what it did.

---

## 9. Things that have actually gone wrong

Each of these cost real time. They are here in the order you are likely to meet them.

1. **`_init` without `super()`** — 50 properties across five nodes stopped invalidating. §4.1.
2. **`@export` with no setter** — emits no `changed`; the node serves its first grid forever. §4.1.
3. **A Dev twin with no `eval_grid`** — inherits a pass-through and freezes it impeccably. §4.3.
4. **`native_out_count()` returning `output_count()`** — a channel the kernel never writes is served as
   zeros, which looks like a real answer.
5. **A hand-rolled solver cache key** — two solvers omitted `gw`/`gh` and could not tell 512×128 from
   128×512. §5.
6. **Overriding `clear_cache()`** instead of `_clear_solver_cache()` — eviction freed nothing and
   destroyed every frozen solve. §5.
7. **Memoising a compiled program** — copied bytes go stale silently. §6.
8. **Calling `evaluate()` from a worker** — refused by design; compile on main, solve on the worker. §3.
9. **Assuming an unwired port means something other than zeros** — the native path binds the zero buffer.
10. **`Signal.is_connected` ignoring binds** — it matches on object+method, so bind-keyed connections
    collapse into one; `Callable ==` and `is_connected` disagree. Bind once into a local and use that
    same Callable for all three of `is_connected` / `connect` / `disconnect`.
11. **Parameters carried at a narrower width than the kernel computes in** — bit-exact for one
    iteration, 0.0008 m out by fifteen. `PASTURE3D_NODE_ACCELERATION_GUIDE.md` §3.6.
