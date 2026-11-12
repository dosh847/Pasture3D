# Pasture3D Graph Ports and Structure Spec

**Status:** P0 built 2026-11-09 (`GraphFormatVersionGate`); P1 built 2026-11-09 (Terrain Bus removed);
P2 built 2026-11-09 (`GraphPortDescriptorGate`; as-built notes in §6.6, editor not yet checked by hand);
P3 built 2026-11-09 (`GraphPortIdGate`; as-built notes in §7.5, editor not yet checked by hand);
P4 built 2026-11-09 (`GraphPortTypeGate [I]`–`[L]`; as-built notes in §8.1, editor not yet checked by hand);
P5 built 2026-11-10 (`GraphStandardMaskGate`, format 3; as-built notes in §9.5, editor not yet checked
by hand); P6 built 2026-11-10 (`GraphParamGate`, no format bump; as-built notes in §10.5, editor not yet
checked by hand); P7 built 2026-11-10 (`GraphSubgraphGate`, no format bump; as-built notes in §11.7, editor
not yet checked by hand); P8 built 2026-11-10 (`GraphMultiInputGate`, no format bump; as-built notes in §12.1,
editor not yet checked by hand). Every phase is built. Written 2026-11-09.
Decisions in §2 were made with the user on that date. Update this header when a phase lands; a status line that says "unbuilt" over half-built code has
misled a session before.

This spec changes how a graph node declares its ports, how a wire identifies the ports it joins, and
what structure a graph can have (masks, parameters, subgraphs). It follows a review of the node and pin
rules against Houdini heightfields, Gaea, World Machine and Blender Geometry Nodes.

---

## 1. What is wrong today

| # | Problem | Where |
|---|---|---|
| 1 | One port is declared in up to seven places, matched by index: `input_count`, `input_names`, `input_port_types`, `input_unwired_default`, `native_param_ports`, `aux_grid_port`, and the editor's `SLOT_SPINS` table keyed by op and port number. | `pasture3d_graph_node.gd`, `graph_editor.gd:1309` |
| 2 | A wire is `[from_node, from_port, to_node, to_port]`, all indices. Removing or reordering a port silently rewires every saved graph, so the dead `transform.offset` socket cannot be removed. | `pasture3d_terrain_graph.gd:49` |
| 3 | A field wired into a value port is read at cell 0, an arbitrary number. The wire is legal. | `register_connection_types` |
| 4 | Type checking lives only in the editor. `connect_ports` accepts anything and `graph_warnings` checks no types. | `pasture3d_terrain_graph.gd:396` |
| 5 | Every unwired port warns "is unconnected and reads 0", including ports set inline and mask ports that read 1.0. | `pasture3d_terrain_graph.gd:2503` |
| 6 | About 40 nodes each implement a `mask` port and their own lerp, in GDScript, C++ and GLSL. | per node |
| 7 | `TERRAIN_BUS` is a fixed five-channel bundle with a special case in `_input_grids`. No saved scene uses it and it lowers natively as a pass-through. | `pasture3d_terrain_graph.gd:2395` |
| 8 | No subgraphs and no graph-level parameters. Reuse is presets and copy/paste. | — |
| 9 | Graphs carry no format version, so an incompatible change cannot be detected at load. | — |

---

## 2. Decisions

| Decision | Choice |
|---|---|
| Old graphs | Graphs are versioned. An incompatible graph is **refused, not migrated**: it does not evaluate, it warns, and the editor does not crash. This repo's scenes are converted by a one-shot tool; the other depot's graphs are rebuilt by hand. |
| Refused graph in a brush | The brush **skips the graph**, baking as if the modifier were absent. |
| Field into value port | **Refused** for new wires. Existing ones keep evaluating and warn. Value ports get a distinct shape. |
| Standard mask | **Every filter and solver that modifies a surface** gets one, applied by the graph compiler. |
| Terrain Bus | **Removed.** |
| Const Vector, Const Curve | **Removed** in P3, with the `VECTOR` and `CURVE` port types retired. |
| Subgraph storage | **Linked asset**: a graph `.tres` referenced by a Subgraph node, flattened at compile. |
| Graph parameters | **One mechanism**: a graph's declared parameters are ports on a Subgraph node and properties on a host brush. |

Three calls made while writing, flagged for review:

* **Runtime wires stay index rows.** Only storage changes to port ids (§7). The compiled program and 174
  `connect_ports` call sites across 34 gates are index-based and gain nothing from changing.
* **"Modifies a surface" is the mask rule.** The standard mask is `lerp(input, output, mask)`, which only
  type-checks when port 0 in and port 0 out are both `HEIGHT`. A Mask or Distance Transform node
  (height in, mask out) therefore does not get one (§9.1).
* **Frozen solvers inside a shared subgraph are refused in the first version** (§11.4). One node resource
  used in two places has one freeze slot.

---

## 3. Phases

| Phase | Content | Breaks saved graphs |
|---|---|---|
| P0 | Format version and refusal | no |
| P1 | Remove Terrain Bus | only graphs using it |
| P2 | Port descriptors, model-side validation, required ports | no |
| P3 | Port ids in storage | **yes, format 2** |
| P4 | Field/value made explicit | no (warns) |
| P5 | Standard mask | **yes, format 3** |
| P6 | Graph parameters | no |
| P7 | Subgraphs | no |
| P8 | Multi-input ports | no |

P0 comes first because every later breaking phase relies on it. P1 comes before P2 so two nodes and one
special case are deleted rather than migrated. P5 follows P3 because moving a `mask` port is only safe
once wires are stored by id.

Every gate criterion below runs beside **a control that must fail**. A criterion that throws before it
asserts counts as a failure, not a pass.

---

## 4. P0 — Format version and refusal

### 4.1 Model

`Pasture3DTerrainGraph` gains:

```gdscript
const FORMAT_CURRENT := 1
const FORMAT_MIN_COMPATIBLE := 0
@export var format_version: int = 0
```

* The script default is **0** on purpose. Godot omits a property equal to its default when saving, so a
  file with no `format_version` line reads as 0, which is exactly "written before versioning".
* A new graph is stamped `FORMAT_CURRENT`, which is non-default and therefore saved. The stamp is at the
  creation sites, **not in `_init`**: `_init` also runs on load, and would turn every pre-versioning file
  into a current one. The sites are `create_default`, the spline preset builder, and the first `add_node`
  on an empty graph (which covers the inspector's bare New Pasture3DTerrainGraph).
* `is_compatible()` is `format_version >= FORMAT_MIN_COMPATIBLE and format_version <= FORMAT_CURRENT`.
  A file newer than the plugin is refused too. A graph with no nodes and no wires is always compatible:
  it has no layout to misread.
* A graph built by assigning `nodes` and `connections` directly, as most gates do, stays at 0. That is
  compatible today and stops being so in P3, which is when those gates get stamped.
* P0 ships with `MIN_COMPATIBLE = 0`, so no saved graph is refused yet. P3 raises both constants to 2.

### 4.2 Refusal

An incompatible graph:

* `evaluate`, `compile_graph_program`, `compile_graph_program_multi`, `compile_cell_program`,
  `native_supported`, the sink pass, the export entry point and the preview pass return their existing
  "nothing" result (empty program, a flat zero grid, no sinks) **before reading a node or a connection**.
  As built there are three choke points rather than a guard per function: `output_index()` returns -1,
  and `_eval_order` / `_eval_order_multi` return empty, so a caller passing an explicit root is refused
  too. The three `sinks_of` functions return empty.
* `graph_warnings` returns one line naming both versions and nothing else.
* The host drops the graph from its stack. `Pasture3DNodeGraph.is_active()` already requires
  `graph.output_index() >= 0`, so the refusal reaches the brush with no edit there. `outward_reach`,
  `reads_footprint` and `reads_input` answer as an absent graph would.
* The graph editor shows a banner with the two versions and does not build the canvas. Nodes are never
  instantiated as `GraphNode`s, so a port list that no longer matches its wires is never drawn. Add Node,
  Presets, Group Frame, Arrange, the bake buttons, the canvas add menu and paste are off for that graph.

### 4.3 Gate — `GraphFormatVersionGate`

| | Criterion | Control |
|---|---|---|
| A | A graph stamped outside the range returns empty programs and a flat evaluation, and warns with exactly the refusal line. | The same graph object stamped current compiles, evaluates non-zero and is native-supported; set back to current afterwards it runs again. |
| B | A host brush holding a refused graph bakes bit-identical to the brush with no modifier, on both raster routes. | The same graph stamped current moves the bake by more than 0.5 m. |
| C | A refused graph whose `connections` name out-of-range nodes and ports raises no script error across 17 entry points. | — (a script error aborts the criterion before it counts, and the gate fails on the count of sub-cases reached) |
| D | A graph made by `create_default` or by a first `add_node` is stamped, and reloads with `format_version == FORMAT_CURRENT`. | A graph saved at 0 writes no `format_version` line and reloads as 0. |

No test seam was needed: the range is [0, 1], so the gate stamps a graph -1 or 99 and is refused from
both sides with the shipped constants. Run with `is_compatible()` forced true, the gate reports 15
failures.

Not gated: the editor banner. `_rebuild` needs a live `GraphEdit`, and a Control outside a tree reports
nothing useful headless. It has to be checked by hand in the editor, and as of 2026-11-09 has not been.

---

## 5. P1 — Remove Terrain Bus

Delete `terrain_bus_merge`, `terrain_bus_split`, their registry entries, the widening branch in
`_input_grids`, the two `GRAPH_OP_OUTPUT` rows at `src/pasture_3d_util.cpp:1281`, `GraphTerrainBusGate`
and its `gates.txt` line, and the bus cases in the other gates that mention it.

`PortType.TERRAIN_BUS = 8` stays in the enum as a retired member with its colour slot. Enum values are
indices into `PORT_COLORS` and into saved data and are never renumbered.

A saved graph that used a bus node loads with a null node, which the evaluator already tolerates.

**As built (2026-11-09).** All of the above, plus:

* `TERRAIN_BUS` is no longer a field type (`is_field_type`), has no preview representation, and is not
  registered as a connection type. It is an enum member and a colour slot and nothing else.
* `GraphAllNodeSocketsGate`'s control "an unmapped port 4 still declines the native path" used
  `terrain_bus_merge` as its subject, and that was the only registry node with an unmapped high port.
  The control now uses a gate-local five-port Reroute subclass, and first asserts that fixture is
  native-supported before port 4 is wired.
* No P1 gate was added: the phase only deletes. It is covered by the gates that walk the registry
  (`GraphAllNodeSocketsGate`, `GraphPortTypeGate`, `GraphOpVocabularyGate`, `GraphPaletteAndConstantsGate`).
* Not exercised: loading a saved graph that held a bus node. No file in this repo has one.

---

## 6. P2 — Port descriptors

### 6.1 The descriptor

One object per port, declared once by the node:

| Field | Meaning |
|---|---|
| `id` | `StringName`, unique within the node's inputs (or outputs). **Stable forever**; it becomes the wire's identity in P3. |
| `label` | Editor text. Free to change. |
| `type` | `PortType`. |
| `default` | What the port reads unwired. |
| `required` | Unwired is a warning. Default false. |
| `property` | For a value port: the node property that is its inline widget and its unwired value. |
| `native_slot` | For a value port: the params slot a wire overrides. `-1` for a field port. |
| `aux` | Marks the node's secondary grid operand. |

A node overrides two functions and nothing else about ports:

```gdscript
func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"in", PortType.HEIGHT).require(),
		Pasture3DGraphPort.value(&"amount", PortType.FLOAT, &"amount", 3),
	]

func _outputs() -> Array[Pasture3DGraphPort]:
	return [Pasture3DGraphPort.field(&"out", PortType.HEIGHT)]
```

`field()` and `value()` are separate constructors so the field/value invariant of the port types guide
(§2 there) is true by construction: a value port has a slot and a property, a field port has neither.

### 6.2 What it replaces

`input_count`, `input_names`, `input_port_types`, `input_unwired_default`, `native_param_ports`,
`aux_grid_port`, `output_count`, `output_names` and `output_port_types` become **final, derived**
accessors on the base, the same move already made for `output_port_type`. `SLOT_SPINS` is deleted; the
editor builds the inline widget from `property`.

The derived accessors are memoised per node instance and cleared on `changed`, because the evaluator
calls them inside loops. Port lists are per **instance**, not static: P7's Subgraph node derives its
ports from the graph it holds.

Ids are taken from today's `input_names()` / `output_names()` entries, which keeps P3's conversion a
pure index-to-name lookup. Where a node repeats a name, P2 renames it and records the rename here.

### 6.3 Migration

Mechanical, about 133 node scripts including the Dev twins and
`templates/template_graph_filter_node.gd`. Before touching a node, `GraphPortTypeAudit` writes its full
port table to a golden file. After, the derived table must equal it.

Two things are audited rather than assumed:

* Whether any node's `input_unwired_default` disagrees with the property its `SLOT_SPINS` entry names.
  If one does, the two routes disagree today and it is reported to the user, not silently unified.
* Whether any port's widget in `_append_slot_special_widget` cannot be expressed as one `property`
  (Const Vector's paired X/Y is one). Those stay as special widgets keyed by port id.

### 6.4 Model-side validation

The connection matrix moves from `Pasture3DGraphEditor.register_connection_types` to a static
`Pasture3DGraphNode.can_connect(from_type, to_type)`. The editor registers from it.

* `connect_ports` returns `bool` and refuses an out-of-range port or a pair `can_connect` rejects.
* `graph_warnings` reports each stored wire that fails the same check.
* Only `required` unwired ports warn, and the message states the port's actual default.

### 6.5 Gate — `GraphPortDescriptorGate`, and updates to `GraphPortTypeGate`

| | Criterion | Control |
|---|---|---|
| A | Every registered node's derived port table equals the golden table. | One altered golden row is detected. |
| B | Every demo graph compiles to a byte-identical program before and after. | A graph with one port type changed does not. |
| C | Input ids are unique per node, and output ids are unique per node. | A fixture node with a duplicate id is caught. |
| D | Every `property` named by a descriptor exists on its node. | A fixture node naming a missing property is caught. |
| E | `connect_ports` refuses `PATH -> HEIGHT` and leaves `connections` unchanged. | `HEIGHT -> HEIGHT` is accepted. |
| F | A graph with only optional ports unwired produces no unwired warning. | Unwiring a required port produces one. |

### 6.6 As built (2026-11-09)

`Pasture3DGraphPort` is `graph/pasture3d_graph_port.gd`. 134 node scripts and two bench fixtures now
declare `_inputs()` / `_outputs()`; no script outside the base defines any of the nine accessors.

Where the build differs from the text above:

* **The cache is keyed on `_dirty_revision`**, which every `changed` bumps, rather than cleared by a
  signal handler. A port backed by a `property` is not cached at all: `input_unwired_default` reads the
  property live. A port whose descriptor is computed from a property inside `_inputs()` (Gradient's
  `start.x`, Gavoronoise's range sentinel, the output type of Gradient / Value Ramp / Relative
  Elevation, Measure's output labels) depends on that property's setter emitting `changed` and on the
  node's `_init` chaining `super()`. Gate [A] reads, sets, and reads again for each of those.
* **`field()` ports can be property-backed** through `.backed_by()`. None is today; the constructor split
  still holds for `native_slot`, which no field port has.
* **Measure's outputs keep the ids `min` and `max` in every mode** and only their label follows the mode.
  The alternative was an id that changes with a property, which P3 could not store.
* **No id was renamed.** No node repeats a name within its inputs or within its outputs.
* **The golden is written by `bench/GraphPortTableWrite.gd`** (table in `GraphPortTable.gd`), not by
  `GraphPortTypeAudit`. It was taken before any node changed and has not been regenerated since.
* **A second baseline, `bench/GraphPortProbe.gd`,** moved every property of every node and recorded which
  ports' unwired value followed. It was run before and after the migration and the two outputs were
  identical. It is what found the six nodes above; the table alone could not, because it is taken on a
  default-constructed node. The probe is kept; its before/after outputs were scratch files.
* **Criterion B covers every registered op, not "every demo graph".** There are no standalone graph files:
  every authored graph is a sub-resource of a demo scene. `bench/GraphPortPrograms.gd` compiles two
  fixtures per op (unwired, and one Const driving every scalar input) and fingerprints the program;
  166 of 302 lower. The golden was produced by running the same script against a copy of the
  pre-migration `graph/` directory. The control moves one port's params slot rather than its type,
  because a type alone does not reach the compiled program.
* **`can_connect` allows a type to itself**, which is also GraphEdit's built-in rule, so COLOR to COLOR
  and the others were always legal. The editor registers only the cross-type pairs. Gate [G] compares the
  two over every pair.
* **`_append_slot_special_widget` is still keyed by op and port number**, not port id, and was not touched.

Audit results:

* `SLOT_SPINS` against the unwired defaults: **no disagreement** on any of its 86 live entries.
* Its `const` and `const_int` rows named port 0 of nodes that have no input port; the caller only builds
  inline widgets for rows below `input_count()`, so those two rows never drew anything. The same is true
  of the `const_vector` / `const_color` / `const_bool` / `const_curve` cases in
  `_append_slot_special_widget`. Found, not changed.
* **39 ports gained an inline spin box** because they were property-backed but absent from the table:
  Contrast `amount`; Displace `amount`; Distance Transform `threshold`; Expand/Shrink `radius`,
  `amount`; Falloff `strength`, `radius`; Flooding `water_level`; Gavoronoise `amplitude`, `angle`,
  `frequency`, `variation`; Gradient `height_min`, `height_max`; Hydraulic Particle `erosion_speed`,
  `deposition_speed`; Stream Log `iterations`, `incision_rate`; Leveler `target_height`; Mudslide
  `amount`; Recast Canyon `gamma`, `amount`; Recast Cliff `talus`, `amplitude`; Relative Elevation
  `radius`; Smooth Fill `radius`, `k`; Transform `rotation`, `scale`, `amount`; Value Ramp `in_min`,
  `in_max`, `height_min`, `height_max`, `amount`; Warp Downslope `amount`; Water Mask `shore_width`;
  Dev Ridge Sharpen `radius`, `amount`. These replace the "+" promote button on those rows.

Required ports. The rule applied: a field port with no backing property that reads 0 unwired and is not
the aux operand. That marked 151 ports; 46 were then made optional by hand because 0 is a meaningful
reading for them: `dx` / `dy` on the five mountain generators, Shattered Peak, Salève and Displace;
Mountain Range Radial `ctrl`; Caldera and Recast Canyon `noise`; Gradient `warp`; Thermal Erosion
`hardness`; Export Splat `r` `g` `b` `a`; Control Sink `blend`. 105 remain required. Every mask that
reads 1 and every value port is optional, so a graph that warned once per unwired port now warns only for
those 105.

Existing gates that had to change, and why:

- `GraphEditModelGate` [D] wired two Consts into a third Const, which has no inputs. `connect_ports` used
  to store that wire; it now refuses it, so the fixture's target is a Blend, as its comment always said.
- `GraphPortTypeGate` listed two known inert ports and now lists one. `native_param_ports()` is derived
  and is empty when no port has a slot, so Export Normal Map, which declared `[-1, -1]` by hand, is
  skipped by that sweep with every other node that has no params map. Its `normal` port is unchanged.
- `GraphOperatorGate` and `GraphPortTypeGate` ask `is_valid_connection_type(t, t)`, which only answers
  for registered pairs, so the editor registers all 54 pairs `can_connect` allows, same-type included.

- `GraphExportGate` [F] wired a Mask into Export Normal Map's VECTOR `normal` port to provoke the
  writer's refusal. That wire is now refused earlier, so the fixture wires a Vector constant and checks
  the wire was accepted.

One migration error got past `GraphPortDescriptorGate` and was caught by `GraphHydraulicParticleGate`:
Hydraulic Particle's `droplets` port was migrated with a fixed unwired default of 25000 where the old
code returned `droplet_count` live, so the GDScript route solved 25000 droplets whatever the property
said. The probe behind criterion A walks `get_property_list()`, and `_validate_property` hides Droplet
Count in METRIC, so the probe never moved it; the golden table holds default-property values only. Every
old `input_unwired_default` body was then compared against its new descriptors from source, and this was
the only mismatch. The gate still cannot see a live default behind a property that is hidden at its
default settings.

Pre-existing failures, identical on the pre-P2 code and not addressed here: `GraphDevTwinGate`
(`dev_dla.amplitude`), `GraphFrozenSolverGate` (dla does not serve its frozen cache),
`TerrainRealismNodesGate` [A] (expects three Hydraulic Erosion outputs, the node has four) and
`RoadGraphGate` [K] and [O] (0.25 m worst height difference).

Not verified: the editor itself. The widgets, the wire refusal in the canvas and the new warnings were
checked through the model and through `_spin_from_hint` headless, and have not been looked at in the
editor.

---

## 7. P3 — Port ids in storage (format 2)

### 7.1 Storage

A new stored property holds the wires; `connections` stops being stored and is rebuilt from it.

```gdscript
## Stored. Each row: [from_node: int, from_id: StringName, to_node: int, to_id: StringName]
@export var wires: Array = []
## Runtime only, index rows, rebuilt from `wires`.
var connections: Array = []
```

* `connections` remains the working form. Every reader, the compiled program and every gate are unchanged.
* `connect_ports` / `disconnect_ports` update both.
* Resolution runs after `nodes` is populated, not inside the `wires` setter, because property load order
  is declaration order and a setter cannot assume `nodes` is there.
* A row whose id no longer exists on its node is **dropped and reported** in `graph_warnings` by node
  and id. It is never rebound to another port.
* `serialize_subgraph` / `deserialize_subgraph` (copy, paste, duplicate) use ids.
* Node identity stays an index into `nodes`. That is out of scope.

One point to verify at build time rather than trust: whether Godot's loader still assigns a
non-exported script variable named in an old file. It should not matter, since an old file is refused
before `connections` is read, but the gate asserts it (criterion D).

### 7.2 Version and conversion

`FORMAT_CURRENT = 2`, `FORMAT_MIN_COMPATIBLE = 2`.

A headless tool converts this repo's seven scenes (38 embedded connection arrays): for each graph it
maps each index to the id the node declares, writes `wires`, and stamps the version. It records each
graph's compiled program before and compares after. The tool is deleted once the scenes are committed.
(As built it was a text edit; see §7.5.)

Run it with the editor closed and the plugin compiling cleanly. A failed plugin compile during a
reimport has re-saved demo scenes before.

### 7.3 First use

Remove the dead `transform.offset` `VECTOR` input (port types guide §7). Every later port on that node
shifts down one, and no wire moves. That is the proof the phase did what it was for.

With that input gone, **Const Vector** drives nothing, and **Const Curve** already drives nothing. Both
are removed in this phase (decided 2026-11-09):

* Delete `const_vector` and `const_curve`, their registry entries, Const Vector's paired X/Y widget in
  `_append_slot_special_widget`, and their cases in `GraphPaletteAndConstantsGate` and
  `GraphPortTypeGate` (`[F]` lists Const Curve as a known dead end today).
* `PortType.VECTOR = 2` and `PortType.CURVE = 3` stay in the enum as retired members with their colour
  slots, like `TERRAIN_BUS`. Their self-connection pairs leave `can_connect`.
* A node that takes a curve keeps it as a `Curve` property, as Curve and Value Ramp do now.
* The format-2 converter drops any wire from either node and reports it. If neither appears in this
  repo's scenes, the converter says so rather than staying silent.

A vector or curve wire can come back later as a new type with a real carrier; the graph bus is scalar
floats and cannot hold one today.

### 7.4 Gate — `GraphPortIdGate`

| | Criterion | Control |
|---|---|---|
| A | Save and reload preserves every wire of every demo graph. | A reload with one id renamed in the file drops exactly that wire and warns. |
| B | Each converted demo graph compiles byte-identical to its pre-conversion program. | — (compared against the recorded program; a missing record fails) |
| C | Inserting a port at index 0 of a fixture node leaves a saved graph's wires on the same ports by id. | The same edit under index storage moves them. |
| D | A format-1 file is refused and raises no script error. | The converted file evaluates. |
| E | Transform evaluates identically before and after the `offset` port is removed, native and GDScript. | — |
| F | No registered node declares a `VECTOR` or `CURVE` port, and neither type connects to anything. | A fixture node declaring one is caught. |

### 7.5 As built (2026-11-09)

**Storage.** `wires` is `@export_storage`. Its setter keeps the loaded rows and resolves them as soon as
`nodes` is there; the `nodes` setter resolves again when rows are still waiting, so either load order
works. Its getter derives the rows from `connections` on every read rather than caching them, so
`connect_ports`, `disconnect_ports` and a direct `connections = [...]` assignment need no second
bookkeeping path and cannot leave the two out of step. A dropped row is reported by `graph_warnings`
("A saved wire was dropped: ...") and is gone from the file at the next save.

**`create_empty()`.** `Pasture3DTerrainGraph.new()` is format 0, which is now refused. A static
`create_empty()` returns a graph stamped `FORMAT_CURRENT`; `create_default()` and the spline preset use it,
and 279 call sites in 116 bench files were switched to it. `GraphFormatVersionGate` keeps `.new()` on
purpose and now asserts format 0 and format 1 are refused.

**Conversion.** Done as a text edit of the seven `.tscn` files, not by loading the scenes (a headless
scene load is what has re-saved demo scenes before). 39 graphs, not 38, and 226 wires. Each graph was
lifted into a standalone `.tres`, recorded (`bench/GraphPortIdRecord.gd`: ops, index rows, ids, problems,
compiled programs), converted, and recorded again: 0 fields differ across the 39. No scene held a Const
Vector, a Const Curve or a wire into `transform.offset`, so nothing was dropped. The converter was a
scratch script and is not in the repo; `GraphPortIdRecord.gd` stays because the gate uses it.

**The gate reads snapshots.** `bench/fixtures/graph_port_id/` holds the 39 converted graphs as `.tres`
files and `bench/golden/graph_port_id_records.json` the pre-conversion record. The gate does not open the
demo scenes, so a later edit to a scene's graph is not covered by [A] or [B].

**The loader does assign `connections` from an old file** (§7.1's open point): a format-1 file loads with
its index rows in place. The graph is refused on its version, so they are never evaluated; [D] asserts it.

**Deviations.**

* `export_normal_map.normal`, the other dead `VECTOR` input, was removed as well, with the writer's
  by-name refusal in `graph_export_sinks.gd`. `GraphExportGate [F]` now checks the sink has one input.
* Mountain Range Radial's `angle` output (and its dev twin) was typed `VECTOR`. It is a scalar field and
  is now `FIELD`. Without this, criterion F could not pass.
* `TERRAIN_BUS` refuses its self-connection too (`is_retired_type` covers all three). Legal ordered
  pairs: 51.
* [E] compares the node against the transform kernel called directly, GDScript and native, with a control
  that a different `offset` property moves the result. There was no before-record to compare with.
* [G] is extra: the radial `angle` output is a `FIELD` and still evaluates.
* `KNOWN_INERT_PORTS` and `KNOWN_UNREACHABLE_OUTPUTS` in `GraphPortTypeGate` are now empty.

**Verification.** `GraphPortIdGate` 47/47. Of the 121 bench gates whose scripts build graphs, 107 pass
and 7 skip or run partial for want of a RenderingDevice headless. The 7 that fail were not caused by this
phase: `GraphDevTwinGate`, `GraphFrozenSolverGate`, `TerrainRealismNodesGate` and `RoadGraphGate` fail
identically on the pre-P2 tree; `GraphSolverFreezeGate` is the same DLA freeze fault as
`GraphFrozenSolverGate`; `GraphChannelLoweringGate [D]` expects Lake Flooding to write one native channel
and it has written three since before this work; `GraphHydraulicGridGate` fails only its three GPU
criteria, which need a RenderingDevice. The last three were not A/B-tested against the old tree. Not
checked: the editor by hand, and the full `gates.txt`.

---

## 8. P4 — Field and value made explicit

* `can_connect` drops every field-to-value pair. Value-to-field stays: a constant fills every cell.
* Value ports draw with a diamond slot icon; field ports keep the circle.
* Dragging a field onto a value port offers **Insert Measure**, which is the node that reduces a field
  to a number on purpose.
* A stored field-to-value wire keeps evaluating as it does now and adds a graph warning naming the
  node, the port, and "reads cell 0". It is not dropped, so this phase needs no format bump.
* Port types guide §6 is rewritten.

Gate, added to `GraphPortTypeGate`:

| | Criterion | Control |
|---|---|---|
| A | No field type connects to any value type in the real matrix. | Value-to-field still connects. |
| B | `Const Float`, `Const Int`, `Const Bool` and both `Measure` outputs connect to a `FLOAT` port. | A `Noise` output does not. |
| C | A graph holding a stored field-to-value wire warns and evaluates as before. | The same graph with a Const in its place does not warn. |

### 8.1 As built (2026-11-09)

* `can_connect` refuses the 12 field-to-value pairs through a new `reads_cell_zero(from, to)`; `is_value_type`
  is new. 39 legal ordered pairs, down from 51.
* No demo scene held a field-to-value wire (0 of 226), so nothing in the repo warns.
* The warning replaces the generic "A wire is not valid" line for this one case. It reads
  "Transform: input 'rotation' is wired to Noise 'out', which is a field, and reads cell 0 of it: ...".
* **Paste and Duplicate keep such a wire.** They go through `connect_ports`, which would have dropped it, so
  `deserialize_subgraph` appends it directly. Not in the spec; without it Duplicate changed what the copy
  evaluated to.
* **Insert Measure.** GraphEdit does not report a drop on a port it will not connect to; it emits
  `connection_to_empty` (or `connection_from_empty`). The editor hit-tests the release position against
  every port (`_port_at`, 28 px at zoom 1) and, when the pair is field to value, shows a one-item menu
  instead of the node search. Both drag directions are handled. The Measure's first output is wired.
* **Diamond.** A generated white texture set as the slot's custom icon, tinted by the slot colour. `COLOR`
  ports keep the circle: the rule is `is_value_type`, which is the three scalar value types.
* The gate is criteria `[I]` (spec A), `[J]` (B), `[K]` (C) and `[L]` (Insert Measure, undo, the icons) in
  `GraphPortTypeGate`, which now also fails when its check count is not exactly 47.
  `[K]`'s "evaluates as before" is: bit-identical to the same graph with a Const holding the source's
  cell 0, and different from the unwired graph. Its first run failed that second half, because the Noise
  fixture had no `FastNoiseLite` and read 0.
* **A cost of the rule:** there is no node that does arithmetic on values. A Math node outputs a field, so
  a computed number can no longer reach a value port. Before, that worked by reading cell 0 of a uniform
  field. Open question for P5 or later.
* `GraphOperatorGate [A]` listed `HEIGHT -> FLOAT`, `HEIGHT -> INT` and `MASK -> FLOAT` as wires the matrix
  must accept. They moved to its refused list. `GraphPortDescriptorGate` counts 39 pairs.
* The 121 bench gates that build graphs give the same verdicts as after P3 (same 7 failures, §7.5), with
  these gates passing.
* Not checked: the editor by hand. The hit-test and the popup position depend on real layout, which a
  headless run does not have; the gate covers the decision and the action, not the drag.

---

## 9. P5 — Standard mask (format 3)

### 9.1 Rule

A node gets the standard mask when its role is FILTER or SOLVER, its port 0 input is `HEIGHT` and its
port 0 output is `HEIGHT`. The base appends the port; a node does not declare it.

```
out0 = lerp(in0, node_out0, clamp(mask, 0, 1))      non-finite mask reads as 1
```

The port has id `mask`, type `MASK`, default 1.0, is always the last input, and is optional.

A node answers one of three ways through `mask_mode()`:

| Mode | Meaning | Example |
|---|---|---|
| `FRAMEWORK` (default) | The compiler applies the lerp. The node never sees the mask. | Contrast, Terrace, Smooth |
| `OWN` | The node receives the mask and applies it itself, because its secondary outputs or its solve depend on it. Same port, same look. | Salève, whose `eroded_rock` and `sediment` follow the mask |
| `NONE` | No standard mask, by the rule above or by opt-out. | Reroute, sinks, Blend (its mask already is the lerp) |

A mask the solve reads as **input data**, not as an output blend, is a different port with a different
id. Mudslide's mask is the source area of mobile material; it is renamed (proposed `source`) and the node
also gains the standard mask.

### 9.2 Implementation

When the mask port is wired on a `FRAMEWORK` node, the compiler emits one extra Blend MIX op after the
node's slot, and every consumer of the node's port 0 reads that slot. Unwired costs nothing.

* It is done in the shared lowering, so `compile_graph_program`, `compile_graph_program_multi`, the cell
  fold, the GDScript evaluator and the GPU route all get it from one place. No new native op, and no
  pressure on the four-field-input limit.
* A frozen solve is unmasked. Changing the mask re-runs one blend, not the solve.
* The thumbnail of a masked node shows the masked result.
* The node's `aux` flag is cleared where the mask was its secondary grid.

### 9.3 Migrating the existing mask ports

About 40 node scripts have a `mask` port. Each is classified **by reading what the node does with it**,
never by its name, and the table is brought to the user before any node changes:

| Class | Action |
|---|---|
| Pure output lerp | `FRAMEWORK`. Delete the node's lerp from GDScript, C++ and GLSL. |
| Output lerp, plus secondary channels or a companion scalar (`mask_amount`) | `OWN`, or fold the scalar into the node's existing amount. Per node, user's call. |
| Solve input | Rename the port, add the standard mask. |

Moving a lerp from a kernel into a separate op changes float rounding. A shared GLSL function has moved
GPU results by 6e-6 m before. Parity gates are expected to move at that scale; rebaselining is done per
node with the before and after numbers shown.

Because ports are renamed and reordered, this is `FORMAT_CURRENT = 3`, `MIN_COMPATIBLE = 3`, with the
same convert-and-delete tool pattern as §7.2. The converter maps old port ids to new ones from an
explicit rename table.

### 9.3.1 Classification (accepted by the user as written 2026-11-10, built)

Read from each node's kernel, not its port name. "Rule" nodes are FILTER or SOLVER with `HEIGHT` in and
`HEIGHT` out on port 0. Dev twins follow their primary. "Proposed" below is what was built; the items the
table left open (Scree, and the native route of Depression Filling and Lake Flooding) were settled before
any node changed and all three are `FRAMEWORK`. §9.5 has the as-built differences.

**A. Nodes that have a `mask` port today**

| Node | What the kernel does with it | Class | Proposed |
|---|---|---|---|
| Recast Canyon | `z + (recast - z) * amount * mask`; `recast` depends on `z` alone | pure lerp | `FRAMEWORK` |
| Recast Cliff | `z + amplitude * (s - 0.5) * amount * gate * mask` | pure lerp | `FRAMEWORK` |
| Ridge Sharpen | `in + amount * mask * lift` | pure lerp | `FRAMEWORK` |
| Strata | `x + (stepped - x) * t`, `t` = amount x elevation window x outcrop x mask | pure lerp | `FRAMEWORK` |
| Contrast | `v + (shaped - v) * mask_amount * mask` | lerp + companion scalar | `FRAMEWORK`, delete `mask_amount` (a Const into `mask` is the same thing). No demo graph sets it. |
| Smooth Fill | `z + (h - z) * amount * mask`, and `deposition` = that delta, normalised | lerp + secondary channel | `OWN`, so `deposition` keeps following the mask |
| Salève | `(1 - w) * in + w * eroded`, `w` = strength x mask; `eroded_rock` and `sediment` are scaled by `w` | lerp + secondary channels | `OWN` (the spec's example) |
| Displace | scales the **offset distance** per cell, then samples | not a lerp | `OWN` |
| Warp Downslope | scales the **displacement in metres** per cell, then samples | not a lerp | `OWN` |
| Hydraulic Particle | a droplet born on a masked-off cell is discarded; every erode and deposit is scaled by the mask | inside the solve | `OWN` |
| Hydraulic Stream Log | scales per-cell incision inside the iteration | inside the solve | `OWN` |
| Mudslide | the mask **is** the depth of mobile material; unwired, the node derives it from slope | solve input | rename `source`, add the standard mask |
| Leveler | the mask is the area whose level is measured and flattened (with the loop) | solve input | rename `area`, add the standard mask |

Displace and Warp Downslope are the two the lerp would visibly change: half a mask gives half the
displacement today, and would give a 50/50 mix of displaced and undisplaced terrain as `FRAMEWORK`.

**B. `MASK`-typed ports that are not called `mask`**

| Node | Port | What it is | Proposed |
|---|---|---|---|
| Terrace | `amount` | per-cell cross-fade backed by the Amount property: the standard mask under another name | `amount` becomes a `FLOAT` value; the per-cell job moves to the standard mask (`FRAMEWORK`). A stored field wire into `amount` converts to `mask`. |
| Depression Filling | `amount` | typed as a field, but the GDScript route reads cell 0 | retype `FLOAT`; `FRAMEWORK` |
| Lake Flooding | `flood_percent` | typed as a field, but the GDScript route reads cell 0 | retype `FLOAT`; `FRAMEWORK` |
| Erosion Thermal | `hardness` | solve input, correctly named | unchanged; `FRAMEWORK` |

The native route for Depression Filling and Lake Flooding has not been read; if it is per-cell there, the two
routes already disagree and that is a bug to fix first.

**C. Rule nodes with no mask today**

`FRAMEWORK`: Warp, Transform, Falloff, Expand/Shrink, Smooth, Talus Projection, Spectral Equalizer, Curve,
Remap, Invert, Flooding Uniform Level, Erosion Hydraulic, Erosion, Stream Extraction, Path Carve, Road Grade,
DLA. `NONE`: Reroute.

**Scree** needs a look before it gets one: its port 0 is described as "the deposited relief", and if that is
the deposit rather than input plus deposit, `lerp(in, out, mask)` is not a blend of two surfaces.

For the multi-output solvers in this list, `FRAMEWORK` masks port 0 only. Their other channels (flow,
sediment, water depth) describe the unmasked solve.

**D. Outside the rule, unchanged**

Blend and Color Blend (the mask already is the lerp), the sinks, Measure's `selection`, the mountain
generators' `envelope`.

**Stored wires this touches in the demo scenes:** 5 of 226 (Salève 2, Displace 1, Ridge Sharpen 1,
Leveler 1). Only the Leveler one is renamed.

**Behaviour changes to accept or refuse**

* A non-finite mask cell reads 1 under the standard rule. Displace, Warp Downslope, Recast Canyon, Leveler
  and Mudslide read it as 0 today; Strata, Ridge Sharpen, Contrast, Smooth Fill and Recast Cliff as 1.
* The dev twins of Spectral Equalizer and Talus Projection have a `mask` their primaries lack.

### 9.4 Gate — `GraphStandardMaskGate`

| | Criterion | Control |
|---|---|---|
| A | For every `FRAMEWORK` node: mask 0 returns the input, mask 1 returns the unmasked output, exactly. | A mask of 0.5 returns neither. |
| B | For every `FRAMEWORK` node: a half-plane mask leaves the masked-off half bit-identical to the input, on native, GDScript and GPU. | The unmasked half differs from the input. |
| C | An unwired mask compiles to the same op count as the node had before this phase. | A wired mask adds exactly one op. |
| D | A frozen solver's solve count does not rise when only its mask changes. | It rises when its input changes. |
| E | Each migrated node matches its pre-phase masked output within a stated tolerance, on a 128-row or larger grid so the thread pool actually splits. | A deliberately wrong mask (inverted) exceeds it. |
| F | Every node the rule selects has the port, and no node the rule excludes does. | A fixture FILTER with a `MASK` output has none. |

### 9.5 As built (2026-11-10)

* **Base.** `mask_mode()`, `standard_mask_port()` (not `mask_port()`: the channel sinks already own that
  name) and `framework_mask_port()` on `Pasture3DGraphNode`. A node that declares its own input with id
  `mask` keeps it and gets no second one (Blend, Color Blend, Export Mask).
* **Graph.** `_emit_program` emits the Blend MIX slot; `slot_of` is what a port-0 consumer reads and
  `raw_slot_of` the node's own op, which secondary channels read. Anything tapping a node's output goes
  through `Pasture3DTerrainGraph.tap_slot(compiled, node, port)`. The GDScript evaluators drop the mask
  from the node's inputs and call `apply_standard_mask`. The single-cell fold (`compile_cell_program`)
  declines a graph with a wired framework mask, so such a graph takes the grid route.
* **`OWN` nodes** (Smooth Fill, Salève, Displace, Warp Downslope, Hydraulic Particle, Hydraulic Stream
  Log and their dev twins): the mask is the node's aux grid and reaches the native kernel through
  `in_aux`. The native freeze key now reads an aux port at index 4 or above, so a frozen Particle solve
  goes stale when its mask moves.
* **Deleted.** The mask parameter of `ridge_sharpen_grid`, `contrast_grid` (and `mask_amount`),
  `recast_canyon_solve`, `recast_cliff_solve` and `strata_grid`, in C++ and GDScript, and Contrast's
  `mask_amount` property. The dev twins of Spectral Equalizer and Talus Projection lost the `mask` their
  primaries never had. The mask branches of the Contrast, Recast Cliff and Recast Canyon GLSL kernels
  went the same day, with the push constants that fed them.
* **Renames.** Leveler `mask` → `area`, Mudslide `mask` → `source`. Terrace `amount`, Depression Filling
  `amount` and Lake Flooding `flood_percent` are `FLOAT` values on native slot 2.
* **Port order moved** on Displace, Recast Canyon, Hydraulic Particle and Hydraulic Stream Log (the mask
  went last). Wires are stored by id, so no stored graph needed a rename for it.
* **Conversion.** 39 graphs in the 7 demo scenes and the 39 fixtures in `bench/fixtures/graph_port_id/`
  were stamped format 3. One stored wire was renamed, as §9.3.1 predicted: `input.footprint` into
  Leveler `mask` → `area`, in `demo_island.tscn` and its fixture. No file stored `mask_amount`. The
  converter was a scratch script and is not in the repository. Its first run renamed nothing (a regex
  never read a node's id, so no node had an op) and left that wire on the new standard mask;
  `GraphPortIdGate` [B] caught it.
* **Goldens re-recorded.** `bench/golden/graph_port_table.txt`, `graph_port_programs.txt` and
  `graph_port_id_records.json`, after every difference was traced to a change listed here: 44 new mask
  rows, the renames, retypes and reorders above, one Blend slot in every wired `FRAMEWORK` fixture, and
  programs that moved only at or downstream of a changed node. `GraphPortIdGate` [B] is now a format-3
  regression record, no longer a comparison against the pre-P3 graphs.
* **Gates edited** for the new last port or a removed argument: GraphDLANodeGate, GraphErosionNodeGate,
  GraphHybridSocketsGate, GraphNativeFreezeGate, GraphPortIdGate, GraphRecastCanyonGate,
  GraphRidgeSharpenGate, GraphStrataProfileGate, TerrainRealismNodesGate,
  GraphGeomorphologyAccelerationGate (its Talus Projection case now checks the kernel with an all-ones
  mask only, since no node can pass it another).
* **Rounding.** The six nodes whose lerp moved out of the kernel differ from their pre-phase recording
  (`bench/golden/graph_standard_mask/`, 96 x 128) by 7.6e-6 m on both CPU routes. The `OWN` and renamed
  ones are bit-identical.
* **Gate differences from §9.4.** [B] uses a two-level noise mask rather than a half-plane, on Ridge
  Sharpen and Strata, with the inverted mask as the control. [D] reads `is_stale()` rather than a solve
  count, and adds a control: an `OWN` frozen solver does go stale when its mask moves. [A] and [C] cover
  six `FRAMEWORK` nodes, not all of them.
* **GPU.** Headless has no rendering device and the gate reports [B]'s GPU rows as not run. Run
  windowed (the same command without `--headless`) on 2026-11-10: Strata, Contrast, Recast Cliff and
  Recast Canyon carry the input's and the unmasked field's values exactly under a hard mask, and their
  unmasked GPU field is within 1.6e-4 m of the CPU's (Strata; the others within 2.3e-5 m). Ridge Sharpen
  has no GPU route. The windowed run exits 0xC0000409 after printing PASS, a crash at quit.
* **Not verified.** The editor (port placement, thumbnails of masked nodes) has not been looked at.
  Mudslide does not lower to native, as before this phase, so its "native" rows ran in GDScript.

---

## 10. P6 — Graph parameters

### 10.1 Model

A graph declares an ordered list of parameters: `id`, `label`, `type` (`FLOAT`, `INT`, `BOOL` in this
phase), `default`, and a range hint.

A **Parameter** node outputs one of them, chosen by id. It is a value-typed source, so after P4 it
connects to value ports and to fields exactly as a Const does.

### 10.2 Hosts

The value is supplied by whoever holds the graph, never stored on the graph:

* The graph modifier (`Pasture3DNodeGraph`) keeps `param_overrides: {id: value}` and exposes each as an
  inspector property through `_get_property_list`. It calls `notify_property_list_changed` when the
  graph's parameter list changes and emits `changed` from its own setter, since an `@export` assignment
  emits nothing.
* An id absent from the overrides reads the declared default. An override whose id the graph no longer
  declares is ignored and reported.

### 10.3 Evaluation

A Parameter node lowers as the constant op with the host's value substituted at compile.

The consequence is that one graph now compiles to different programs for different hosts. Every key
that today is derived from the graph alone must also hash the overrides: the compiled-program memo,
`content_key`, the per-node `_inputs_hash`, the freeze key, and the editor's preview token. Missing one
is the stale-memo bug this codebase has met before, so the gate checks each key separately.

### 10.4 Gate — `GraphParamGate`

| | Criterion | Control |
|---|---|---|
| A | Two hosts sharing one graph with different overrides bake different terrain, each matching the graph with that value typed into a Const. | Equal overrides bake identically. |
| B | Changing an override re-bakes the host; native and GDScript agree. | Changing an override on a different host does not re-bake this one. |
| C | A frozen solver downstream of a Parameter re-solves when the override changes. | It does not when an unrelated override changes. |
| D | The host's property list tracks an added and a removed parameter. | — |
| E | An override for a removed id is ignored and warned. | — |

### 10.5 As built (2026-11-10)

* **Declaration.** `Pasture3DGraphParam` (`graph/pasture3d_graph_param.gd`): `id`, `label`, `type`
  (FLOAT/INT/BOOL), `default_value`, `range_min`/`range_max`/`step`. The default is one float for all three
  types; `coerce` is the one place a type means anything (FLOAT rounds to float32, INT rounds, BOOL is 0/1).
  The graph holds them as `@export var parameters: Array[Pasture3DGraphParam]`. Editing the list, or any
  declaration in it, emits `changed`, `structure_changed` and a new `parameters_changed` signal.
  `graph_warnings` reports a blank id and a duplicate id (the first declaration wins).
* **Parameter node.** `Pasture3DGraphNodeParam`, op `param`, one value output whose type follows the
  declaration, registered under Constants. It does not hold its value: the graph binds it
  (`_apply_params`) with the declared type and the resolved number, on a declaration edit, a node's
  `param_id` edit, a `nodes` assignment and every host stamp. A bind emits nothing (see below); a bind
  that changes the type moves `_dirty_revision` so the port tables rebuild. An undeclared or blank id
  reads 0 and is reported by `node_warnings`.
* **Lowering.** `{ "param", GRAPH_OP_CONST }` in C++ `graph_op_ids()`, with the bound value in params[0];
  the cell compiler has a `param` arm. No kernel changed.
* **Stamping, not compile arguments.** The host's values reach the graph as `host_params`, stamped by
  `set_host_params` exactly as `host_footprint` is: runtime only, and stamped by the host before every
  compile and evaluate on its behalf. A stamp emits nothing, because `changed` is the bake signal and the
  graph is shared: an emitting stamp would have each host's bake re-bake the others.
* **Host.** `Pasture3DNodeGraph.param_overrides` (`@export_storage`) holds what was set; each declared
  parameter is an inspector property `parameters/<id>` through `_get_property_list`/`_get`/`_set`, with a
  revert to the declared default, and `set_param`/`clear_param`/`param_number` for code. The property list
  is notified on `parameters_changed` and on a graph swap. A value set for an undeclared id is stored (a
  graph swapped in later may declare it) and reported by `modifier_warnings`.
* **Keys.** `graph.content_key()` stays the graph's own revision. `graph.params_sig()` hashes what the
  Parameter nodes read now (0 for a graph without one), and `Pasture3DNodeGraph.graph_key()` stamps and
  returns `hash([content_key(), params_sig()])`, or the bare revision when the signature is 0, so a graph
  without parameters keys exactly as before. `graph_key()` replaced `content_key()` at every host site:
  the brush's compiled block (`_compile_modifiers`, `_prepare_staged_graph_modifiers`), the GDScript
  step's frozen-cache key (`_apply_graph_step`), the modifier's `content_key()` (so `_modifier_signature`)
  and the sink-tap content key. `_compute_node_inputs_hash` appends a Parameter node's value, which every
  downstream node folds in through `_inputs_hash`. The native freeze key needed nothing: it already hashes
  the resolved scalar and grid operands, and the value is one of them. The editor's preview token is a
  per-dispatch counter, not a content key; the editor stamps the host's values before each preview
  compile, the `_upstream_field` evaluate and the inspector's compile, and refreshes on the host's new
  `params_edited` signal, since a value edit emits nothing on the graph.
* **What a value edit does.** It is a host edit, like Strength: it emits the modifier's `changed` and never
  the graph's. It drops this modifier's frozen cache, and the solve of every frozen solver node downstream
  of a Parameter node reading that id (`Pasture3DGraphSolverNode.forget_solve`, which emits nothing), so the
  bake re-solves instead of serving the old solve as stale. A solver not downstream keeps its solve.
* **Limitations.** A frozen solver node in a graph shared by two hosts with different values has one freeze
  slot: whichever host baked last owns it and the other is served that solve, reported stale. There is no
  editor UI for declaring parameters beyond the graph resource's own inspector, and `param_id` is a plain
  text field rather than a dropdown of the declared ids.
* **Gate differences from §10.4.** [A] adds the declared default and a re-bake of host 1 after host 2 (the
  stamp must not leak); [C] runs on both routes; [E] adds a control; [F] is new and checks the two keys the
  bake reaches only indirectly (the per-node inputs hash, through the GDScript evaluator's caches, and the
  cell program). Mutation check: disabling `forget_solve` fails [C] on both routes, and dropping the value
  from `_compute_node_inputs_hash` fails [F] twice.
* **Sweep.** 123 gates. The goldens `graph_port_table.txt` (+4 rows) and `graph_port_programs.txt` (+2
  rows) were re-recorded for the new node, and `GraphPaletteAndConstantsGate` now counts five Constants.
  What still fails failed before this phase: GraphChannelLoweringGate, GraphDevTwinGate,
  GraphFrozenSolverGate, GraphHydraulicGridGate, GraphSolverFreezeGate, RoadGraphGate,
  TerrainRealismNodesGate. Several gates exit 0xC0000005 after printing PASS, the known crash at quit.
* **Not verified.** The editor by hand (the inspector properties, the preview refresh on a value edit, the
  node's port colour following the declared type).

### 10.6 PATH parameters (2026-11-11)

Asked for so several brushes can share one graph and each carve its own spline (four HillRange brushes,
one Spline Source → Range Splines → Path Fractalize → Path Range graph). A shared Spline Source cannot do
it: the node HOLDS its path, so each host's resolve writes the shared property, and each write emits
`changed` on the shared graph, so every host's bake re-bakes every other host.

* **Declaration.** `Pasture3DGraphParam.Type.PATH = 3`. It has no number: `coerce` is 0 and `port_type()`
  is PATH. How the spline is read is part of the declaration (`spline_index`, `sample_points`,
  `sample_interval`, the Spline Source settings). `_validate_property` hides the number settings for PATH
  and the spline settings for the number types.
* **Host value.** A spline KEY (String) in `param_overrides`. The empty key, which is also what an
  unsupplied host reads, is the host brush's own first Pasture3DSpline child (Spline Source's §5.1 rule),
  so duplicated brushes sharing one modifier each read their own child. Setting the key back to empty
  clears the override. The inspector property is a String with the scene's spline keys as an
  ENUM_SUGGESTION.
* **Resolution is the host's.** `Pasture3DNodeGraph.stamp_params(p_host)` resolves each PATH parameter
  through `Pasture3DGraphSources.param_path` and stamps the paths with the values
  (`set_host_params(values, paths)`). The modifier is often shared, so the brush names itself at every
  stamp site. The modifier remembers the last host (weakly) for callers that cannot name one
  (`content_key`, the frozen cache), and the brush stamps itself before `_modifier_signature` reads
  `content_key`. A per-host memo keeps the previous path instance when its `content_digest` is unchanged,
  because downstream path caches and the geometry table key on the instance id.
* **Parameter node.** Bound to a PATH, it outputs a PATH field port and returns the path from
  `path_output()`. It lowers like Spline Source (a zero CONST slot, the path in the geometry table).
  `value_signature()` (the path's `content_digest`, or the number for the number types, so their keys do
  not move) replaces `resolved_value()` in `params_sig` and `_compute_node_inputs_hash`.
* **Spline edits.** `_brush_reads_spline` also counts a PATH parameter whose key on that host names the
  spline, or whose key is empty when the spline is that brush's own child. So an edit re-bakes the brushes
  that read the spline and no others. `_graph_source_brushes` (scoped bake) lists a typed key's spline as an
  input, and `input_spline_polylines` (Spline Fit) includes PATH parameter outputs.
* **Subgraphs.** An unwired PATH parameter inside an instance is pinned to no path: the instance has no
  host to resolve against, so wire a path into the Subgraph node's port. Ungroup replaces an unwired PATH
  parameter with an empty-key Spline Source carrying the declaration's spline settings.
* **Declaring from the node.** Selecting a Parameter node puts Pasture3DGraphParamRow at the top of the
  Inspector: a dropdown of the graph's declared parameters, and a New row (id, type, Declare) that appends a
  declaration and points the node at it, as one undoable action (`Pasture3DGraphEditor.apply_param_edit`).
  The modifier's Parameters section appears once the graph declares one. Gate: `GraphParamRowGate` RA–RD.
* **Warnings.** The modifier warns when a PATH parameter resolves no spline on its host (an empty key on a
  brush with no spline child, or a key naming nothing). The node warns when the last stamp gave it no path.
* **Gate.** `GraphPathParamGate`, PA–PG: each host evaluates its own spline (equal to Spline Source on that
  spline, native = GDScript); a stamp emits nothing (control: a shared empty-key Spline Source emits);
  per-host keys and instance reuse (control: the memo dropped); a typed key; spline-edit routing (control:
  a brush without the parameter); the inspector; `content_key` following the last stamp. PH: an unwired
  Parameter retyped to PATH emits `structure_changed`. PI/PJ: the duplicate split below, and picking the
  host's own spline storing the empty key.

### 10.7 One graph, many brushes: per-host caches (2026-11-11)

Sharing a graph shares its NODES and their settings. It does not share their results: every brush hosting
the graph evaluates it on its own ground, so every cache inside the graph is kept per host.

* **The host is named at the stamp.** `set_host_params(values, paths, host_id)` selects the host (the
  brush's instance id; 0 = no host, a graph edited or tested on its own) on every node through
  `Pasture3DGraphNode.select_host`, which swaps the node's cache fields for that host's slot. Code reading
  `_cached_grid`, `_inputs_hash` or a solver's `_cache` reads one slot, the live host's. The flat view
  (§11.2) is selected with its parent.
* **What is per host.** The GDScript route's per-node grid (`_cached_grid`, `_cached_aux`,
  `_inputs_hash`, `_last_baked_revision`); a solver's frozen solve (`_cache`, `_cache_key`,
  `_dirty_since_bake`, `_stale`), which also feeds the native `frozen` table at compile; the path memo
  (`_path_eval_cache[host][node]`). The modifier's own cache was already per host.
* **Grid budget.** At most 8 other hosts keep a grid on a node; past that the least recently used host's grid
  is dropped (it re-evaluates). A frozen solve is never dropped this way. `get_cache_size_bytes` counts
  every host's grid, and `clear_cache` (eviction) drops every host's grid.
* **Who clears whom.** A node's Bake button (`_clear_solver_cache`) and a node setting edit
  (`mark_dirty_since_bake`) apply to every host: the node is the same for all of them. A parameter
  override is a host edit and forgets only the solves of the hosts that modifier stamped
  (`forget_solve_for`).
* **Native adopt.** A worker's freeze report is adopted with the host it was compiled for
  (`adopt_native_freeze(reports, host_id)`), so a solve landing after another host stamped files into its
  own slot.
* **Duplicating a brush.** Godot shares sub-resources with a duplicate, so a duplicated brush used to share
  its graph modifier (its parameter values, Live/Frozen, modifier cache). In the editor, a brush's `_ready`
  calls `Pasture3DBrushGraphRow.unshare_graph_mods`: each brush gets its own modifier on the SAME graph.
  It runs on load too, so a scene saved with a share is split once. A PATH key naming the spline of another
  brush hosting the same graph is dropped on the copy, so the duplicate reads its own spline.
* **Gate.** `GraphHostSlotGate`: HS (both routes) host 2 gets its own frozen solve and host 1 is served its
  own back (control: one host id serves host 2 host 1's solve); HG grids per host and counted (control:
  one id keeps the last host's); HA adopt files by host id (control: no id files live); HO an override
  forgets its own host's solve only (control: Bake drops both).

---

## 11. P7 — Subgraphs


### 11.1 Model

A **Subgraph** node holds a reference to a `Pasture3DTerrainGraph` resource. Shared when the reference
is an external `.tres`; local after Make Unique.

The child graph declares its interface with nodes:

* **Subgraph Input** (id, label, field type) — becomes an input port on the Subgraph node.
* **Subgraph Output** (id, label, type) — becomes an output port.
* Its **parameters** (P6) — become value ports, each with an inline widget, wired or set per instance.

The Subgraph node's descriptors are derived from the child, which is why P2 made port lists
per-instance. A child interface change raises the parent's revision through the child's `changed`
signal, bound by object and not by a key that goes stale.

A child used at top level in a brush behaves as any graph: its Subgraph Inputs read their defaults.

### 11.2 Flattening

Subgraphs do not exist below the compiler. One function expands a graph into a flat node list and
index wires, recursively, and every evaluator entry point consumes that view. Native, GPU, the cell
fold, previews and sinks see ordinary nodes.

* Child nodes are **duplicated per instance** in the flattened view, cached on the Subgraph node and
  rebuilt when the child's revision moves. Two instances of one child therefore do not share
  `_cached_grid` or thrash each other's input hash.
* A parameter port on the Subgraph node becomes the flattened Parameter node's value: a constant if
  set inline, a wire if wired.
* The standard mask (P5) applies to a Subgraph node with a `HEIGHT` first input and first output.
* `edit_reach` and `outward_reach` are computed over the flattened view.

### 11.3 Refusals

* A graph that contains itself, directly or through a chain, is refused with a warning naming the cycle.
* A child with an incompatible `format_version` makes its Subgraph node pass port 0 through and warn.
  The parent still evaluates.
* A sink or publish node inside a child is refused in this phase. Sinks write to the terrain or the
  disk from entry points that key on the top-level graph, and two instances would write twice.

### 11.4 Frozen solvers — first version

A frozen solver stores its solve on the node resource. Inside a shared child that is one slot for every
instance, and the per-instance duplicates of §11.2 are not persisted.

First version: **a solver inside a subgraph cannot be Frozen.** The Freeze control is disabled there
with a tooltip, and a frozen solver arriving through Group into Subgraph is thawed with a notice.
Lifting this means storing freeze state on the Subgraph node, keyed by child node; it is a follow-up
with its own gate, not part of P7.

### 11.5 Editor

* Double-click a Subgraph node to open the child; a breadcrumb returns to the parent.
* **Group into Subgraph** on a selection: builds the child from `serialize_subgraph`, creates Subgraph
  Input and Output nodes for the wires that crossed the selection boundary, and replaces the selection
  with one node. One undo step.
* **Ungroup** inlines a Subgraph node.
* The built-in presets in `_insert_preset` can become subgraph assets later. Not in this phase.

### 11.6 Gate — `GraphSubgraphGate`

| | Criterion | Control |
|---|---|---|
| A | A graph and the same graph with a region grouped compile to equivalent programs and bake bit-identical, native and GDScript. | Changing a node inside the child changes the bake. |
| B | Two instances of one child with different parameter values produce different outputs, each equal to the inlined equivalent. | Equal values produce equal outputs. |
| C | Editing a shared child re-bakes every parent that references it. | A parent that does not reference it does not re-bake. |
| D | A self-containing graph is refused and raises no script error. | — |
| E | A child at an incompatible version passes port 0 through and the parent's other nodes still run. | — |
| F | Group then Ungroup returns a graph whose program equals the original's. | — |
| G | A rect bake through a subgraph containing a finite-reach node pads by the same distance as the inlined graph. | An INF-reach node inside sends it whole-footprint. |

### 11.7 As built (2026-11-10)

* **Nodes.** `Pasture3DGraphNodeSubgraph` (op `subgraph`), `Pasture3DGraphNodeSubgraphInput` (op
  `subgraph_input`) and `Pasture3DGraphNodeSubgraphOutput` (op `subgraph_output`), registered under
  Routing & Structural. In C++ `graph_op_ids()`, `subgraph_input` lowers to `GRAPH_OP_CONST` (it holds its
  default) and `subgraph_output` to `GRAPH_OP_OUTPUT` (the passthrough Reroute uses). `subgraph` is
  deliberately absent: it never reaches the compiler. A graph used at top level runs its Subgraph Inputs as
  constants holding their defaults.
* **Flat view.** A graph whose `has_subgraphs()` is true delegates every evaluator entry point to
  `flat_view()`. These are `evaluate`, both compilers and the multi compiler, the cell compiler,
  `native_supported` and the staged variant, both block reports, `resolved_path_of`/`stage_paths_for`, both
  reaches, `reads_input` and `reads_footprint`. The flat view is a generated `Pasture3DTerrainGraph`
  (`_is_flat`, never saved, never delegates again). Its top-level nodes are the parent's **own node
  objects at their own indices**, so a preview root, a sink's source and a freeze report mean the same
  node on both sides. After those come each Subgraph node's instance copies
  (`Pasture3DGraphNodeSubgraph.instance_nodes`, cached on the Subgraph node until the child's revision
  moves). The boundary is rewired as the comment above `FLAT_NO_ROOT` describes:
  * Subgraph Input copies are redirected to the parent's wire, or stay constants holding the default.
  * Parameter copies are redirected to the wire if one exists, and are always pinned to the instance's
    value (`Pasture3DGraphNodeParam.pin`, which `_apply_params` respects).
  * Output port k is aliased to whatever feeds the k-th Subgraph Output.
  * A wired standard mask adds one Blend MIX.

  The Subgraph node stays at its index, unwired, and never runs. The flat view is rebuilt when
  `_invalidate_topology_cache` marks it dirty, or when its signature moves. The signature covers each
  Subgraph node's index, `_dirty_revision` and child serial. `_sync_flat` copies the host params,
  footprint, force flags and cache budget in before every use.
* **Taps on a Subgraph node's ports.** `compiled["sub_taps"]` gives one slot per output port, and
  `tap_slot` reads it first. Because each port is its own root, the channel is 0. A new static
  `tap_channel(compiled, node, port)` returns that 0 for a Subgraph node and the port for anything else.
  The channel sinks, export sinks, the Graph modifier's tap and the inspector's tap readout call it instead
  of passing the raw port.
* **Refusals.** Expansion carries a stack of graphs, so a self-containing graph (directly or through a
  chain) is refused, with the cycle named in `graph_warnings`. A muted, cyclic or incompatible Subgraph
  node passes port 0 through; its other output ports read as unwired. The following are dropped from the
  instance copies: a sink or publish node inside the child (with a note), and the child's own Output node,
  which would otherwise take over the parent's output. A frozen solver copy runs Live, with a note. A block report that names an instance
  copy is mapped back to its Subgraph node and gets "(inside the subgraph)".
* **Group / Ungroup.** `group_into_subgraph(indices)` and `ungroup_subgraph(index)` are graph methods; the
  editor wraps each in one undo step that records the whole wiring state (`nodes`, `connections`,
  `output_node`, `output_override` and frame attachments).
  * Group makes one Subgraph Input per distinct outside source and one Subgraph Output per distinct inside
    source. It duplicates the Parameter declarations the selection reads into the child, and wires a new
    parent Parameter node into each parameter port.
  * Group refuses Output nodes, sinks, subgraph boundary nodes, the designated output node, and any
    crossing wire that is not a scalar field (PATH and COLOR do not cross the boundary in this phase).
  * Ungroup redirects wired boundary nodes to their sources and turns unwired ones into constants, and
    re-inserts the Blend MIX if the mask was wired.
* **Editor.**
  * Double-clicking a Subgraph node opens its child in the same panel. A breadcrumb at the left of the
    toolbar leads back, and restores the host the parent was shown through.
  * Group Subgraph (Ctrl+G) and Ungroup (Ctrl+Shift+G) are toolbar buttons.
  * Inside an opened child, a solver node shows a disabled "Live" badge whose tooltip explains §11.4.
* **Limitations.**
  * Scene-naming sources (Spline Source, Mesh Source and so on) inside a child are not resolved host-side,
    so they read empty.
  * Port types across the boundary are scalar only.
* **Gate differences from §11.6.** `GraphSubgraphGate`, 43 checks counted against `EXPECTED_RAN`.
  * [A] adds a masked boundary.
  * [G] is measured at the reach a rect bake pads by: the graph's `edit_reach` and the Mound's
    `_stack_edit_reach`, with a Leveler LEVEL_AT_HEIGHT INSIDE inside. It is not measured by running a
    rect bake. Its control switches the Leveler to FLATTEN (INF).
  * [H] is new. It drives the graph editor: Group and Ungroup each record one undo step, undo and redo
    restore the program, and the breadcrumb opens and closes. Its control is that Group with nothing
    selected records no step.
* **Sweep.** 124 gates.
  * The goldens `graph_port_table.txt` (+12 rows) and `graph_port_programs.txt` (+6 rows) were re-recorded
    for the three new nodes. `bench/golden/` is untracked, so the re-record was checked by the row counts
    and by where the first mismatches fell, not by a diff.
  * `GraphAllNodeSocketsGate` failed on `subgraph`'s missing op id. The fix is a declaration, not an
    exemption list: the node answers `flattens_away()` true. A new control in that gate compiles a graph
    wired through a Subgraph node and requires it to be `native_supported`.
  * The gates that still fail also failed before this phase: GraphChannelLoweringGate, GraphDevTwinGate,
    GraphFrozenSolverGate, GraphHydraulicGridGate, GraphSolverFreezeGate, RoadGraphGate and
    TerrainRealismNodesGate.
  * Several gates exit 0xC0000005 after printing PASS. This is the known crash at quit.
* **Not verified.** The editor by hand: the double-click, the breadcrumb's look, the Ctrl+G shortcuts in a
  live editor, the disabled Live badge, and how the Subgraph node's derived ports draw.

---

## 12. P8 — Multi-input ports

Lowest priority, and only worth building against a concrete need.

* A descriptor flag `multi` lets an input accept several wires. `wires` rows for that port carry an
  order.
* The compiler lowers N wires to a chain of binary ops, so nothing below it changes.
* Only associative, commutative-safe modes qualify: a **Combine** node with add, max, min and multiply.
  Blend's other modes (sub, div, pow, mix) depend on operand order and stay two-input.

Gate: an N-input Combine equals the hand-built chain of Blends bit-for-bit; reordering the wires of an
add within float tolerance, and of a max exactly.

### 12.1 As built (2026-11-10)

* **Port flag.** `Pasture3DGraphPort.multi`, set by `accepts_many()`. `connect_ports` keeps every wire into
  a multi port and appends the new wire last. Connecting the same wire twice still gives one wire. An
  ordinary input still replaces its wire.
* **Order.** The order is the **row order** of the port's wires in `connections`, which is the order they
  were made. `wires` is written from `connections` in that order and read back in it, so no fifth column
  was needed and there is **no format bump**. Every rewrite of `connections` (delete, paste, Group, Ungroup)
  filters or appends rows and keeps their relative order. The editor's Disconnect now undoes by restoring
  the rows, not by reconnecting: a reconnect appends, which would move the wire to the end. That fix is the
  one editor change in this phase. There is no UI to reorder wires. Because every qualifying mode is
  commutative, an order only moves rounding.
* **Combine.** `Pasture3DGraphNodeCombine`, op `combine`, Math & Combiners. It has one multi input, `in`,
  labelled "in (any number)", and modes ADD, MAX, MIN and MUL. Its role is Combiner, so it takes no
  standard mask.
* **Lowering is in the flat view (§11.2), not the compiler.** `needs_flat()` is true when a graph holds a
  Subgraph or a Combine node. Every evaluator entry point that P7 delegated now checks `needs_flat()`
  instead of `has_subgraphs()`, which still means subgraphs only. `_fl_combine` turns the node into a left
  fold of fresh two-input Blends, ((w0 op w1) op w2) …, over its wires in row order:
  * One wire, or a muted Combine, becomes a Reroute of the first wire.
  * No wires becomes a Const 0. The port is `required`, so `graph_warnings` reports it.

  The Combine node stays at its index, unwired, and never runs, as a Subgraph node does. Its fold is its
  `_flat_roots` entry, so previews, taps, the output and block reports find it the same way they find a
  Subgraph port. A block report inside the fold names the Combine node and says "(inside the Combine
  fold)". The flat signature includes each Combine's mode and `muted`, so editing either re-folds.
* **Native.** `combine` is absent from `graph_op_ids()` on purpose. It answers `flattens_away()` true,
  the declaration `GraphAllNodeSocketsGate` reads (P7 added it for `subgraph`).
* **Inside subgraphs.** A child's flat view folds its own Combines, and a Subgraph instance does not copy
  the child's dead Combine node. Group and Ungroup move a Combine and its wires without special cases.
* **Gate differences from §12.**
  * `GraphMultiInputGate` has 42 checks, counted against `EXPECTED_RAN`.
  * [A] runs all four modes at five wires on both routes, and ADD at two and three. Its control changes
    one step of the hand chain to SUB.
  * [B] reverses five wires. ADD moved by 1.2e-4 (float32 rounding at magnitude 1234), within 1e-3. MAX did
    not move. The control shows the reordered program differs, so the reorder reached the compiler.
  * [C]–[F] are new: wiring rules and save/load order, mode edits, subgraphs and Group/Ungroup, and the
    editor's undo.
  * Mutation check: putting back the reconnect-style Disconnect undo fails [F] ("[2, 3, 1]").
  * Programs are compared by a Merkle signature that hashes a program's FastNoiseLite by its settings, not
    its identity. Two equal graphs hold different noise objects.
* **Sweep.** 125 gates.
  * The goldens `graph_port_table.txt` (+5 rows) and `graph_port_programs.txt` (+2 rows) were re-recorded
    for Combine, and `GraphPortDescriptorGate` passes on them.
  * Nothing else moved against the P7 sweep. The same seven gates fail as before this phase:
    GraphChannelLoweringGate, GraphDevTwinGate, GraphFrozenSolverGate, GraphHydraulicGridGate,
    GraphSolverFreezeGate, RoadGraphGate and TerrainRealismNodesGate.
  * Which gates exit 0xC0000005 after PASS changes from run to run. This is the known crash at quit.
* **Not verified.** The editor by hand: drawing several wires into one input, and how GraphEdit's drag
  from a connected input picks which wire to detach.

---

## 13. Rules for creating a node, after P5

This replaces the scattered guidance in the base class comments once the phases land.

1. Declare ports in `_inputs()` and `_outputs()` only. Ids never change after a release.
2. A value port names its `property` and its `native_slot`. A field port names neither.
3. Mark a port `required` only if the node is meaningless without it.
4. Do not declare a `mask` port. Answer `mask_mode()` if the default is wrong for the node.
5. Choose port types by the port types guide §5, by reading the producer.
6. Call `_param_changed()` from every property setter, and chain `super()` from `_init`.
7. Add the registry entry, and the op to `graph_op_ids()` in C++. An op missing there drops the whole
   graph to GDScript.
8. Removing or renaming a port is a format bump with a converter rename row. Adding an optional port
   is not.
9. Declare a multi port (`accepts_many()`) only on a node the flat view lowers away (§12.1). Every
   evaluator below the flat view reads one wire per input.

---

## 14. Related

* `PASTURE3D_GRAPH_PORT_TYPES_GUIDE.md` — the type meanings. §6 (connectivity), §7 (the `VECTOR` rough
  edge) and §8 (adding a type) are rewritten by P2–P4.
* `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §9 — the editor's port rendering, replaced by descriptors.
* `PASTURE3D_TERRAIN_GRAPH_USABILITY_SPEC.md` — `serialize_subgraph` and the copy/paste model P3 and P7
  build on.
