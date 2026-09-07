# Pasture3D Graph Port Types Guide

**Status:** current as of 2026-09-06. The enum has 12 members; `GraphPortTypeGate` holds it consistent.

This is the reference for `Pasture3DGraphNode.PortType` — what each type *means*, how to decide which one a
port should declare, and how to add a new one without breaking the editor. It exists because a port type is
read by four mechanisms that never talk to each other, and **every one of them fails silently** when they
disagree. Nothing errors. You find out weeks later, from a thumbnail that looks wrong.

---

## 1. What a port type is, and what it is not

A port type is a **declaration about the numbers on the wire**: their units, their range, and whether there
is one of them or one per cell. It is **not** a storage format. Every scalar wire in the graph is the same
thing underneath — a `PackedFloat32Array` — and the type is what tells the editor how to colour the socket,
what to let you connect it to, and (from the visualization work) how to *render* the field so a human can
read it.

Because the type carries meaning rather than layout, the honest question when choosing one is never "what
shape is this data" — it is always **"what would a person have to know to read this number correctly?"**

---

## 2. The field / value split

This is the one structural distinction, and it is load-bearing:

| | carries | example |
|---|---|---|
| **field type** | one value **per grid cell** | the terrain a node emits |
| **value type** | **one** value for the whole port | a strength, a count, a toggle |

The split is not a matter of taste. It is enforced by `native_param_ports()`, which the native and GPU
lowering both believe:

> **The invariant.** A port declares a **value** type **if and only if** `native_param_ports()[i] >= 0`.
> A port declares a **field** type **if and only if** that entry is `-1`.

`native_param_ports()[i] = k` means "if port *i* is wired, overwrite `params[k]` with the first float on that
wire." A field type on such a port says a whole grid arrives there — the lowering will take element zero of
it and throw the rest away. A value type on a `-1` port says the opposite: the node is handed a grid it will
read as `p_inputs[i][0]`, and nothing upstream knows that.

`GraphPortTypeGate [C]` checks this in **both** directions. `Pasture3DGraphNode.is_field_type()` is the single
place the membership is decided; do not restate it.

> A node with `blocks_native()` true returns an empty params map, so there is nothing to agree with and the
> criterion skips it. That is why an ad-hoc script that reads a missing entry as `-1` produces false
> positives — it did, during the audit that wrote this guide.

---

## 3. The types

### Field types — one value per cell

| # | Type | Colour | Meaning |
|---|---|---|---|
| 0 | `HEIGHT` | Sky Blue | Elevation in **metres**, absolute. The terrain itself. |
| 1 | `MASK` | Amber | A **normalised [0,1] weight**, by construction. See §4 — this is the type people get wrong. |
| 10 | `FIELD` | Yellow-Green | An **unsigned quantity in its own units**, unbounded. Flow in m², depth in metres, a distance. |
| 11 | `SIGNED` | Magenta | A **signed quantity in its own units**, where **zero is meaningful**. A cut/fill, a residual, a gradient component. |
| 8 | `TERRAIN_BUS` | Warm Gold | A bundle of several channels travelling together. Not a scalar; connects only to itself. |
| 9 | `PATH` | Slate | A `Pasture3DGraphPath` **resource**, not a grid at all. Connects only to itself (see §6). |

### Value types — one value per port

| # | Type | Colour | Meaning |
|---|---|---|---|
| 4 | `FLOAT` | Cyan | A general scalar: a strength, a rate, a radius. The default for a driven parameter. |
| 5 | `INT` | Cobalt Blue | A discrete count or an enum selector. |
| 7 | `BOOL` | Lime Yellow | A toggle. |
| 2 | `VECTOR` | Purple | A direction or angle. **See the caveat in §7.** |
| 3 | `CURVE` | Emerald | A transfer curve. |
| 6 | `COLOR` | Magenta/Pink | An RGBA tint. |

---

## 4. The MASK test — the rule the audit actually turned on

`MASK` is the type that gets mis-declared, because "a number between nothing and a lot" *feels* like a mask.
It is not. The operative test is:

> **A channel is a `MASK` only if something DIVIDED it into [0,1] — and then the divisor is part of its
> meaning and has to be reachable.**

If you cannot point at the line that normalised it, and at where the divisor is stored, it is a `FIELD` (or a
`SIGNED`), whatever its typical range happens to be.

Why this matters concretely: the visualization work renders a `MASK` on an **absolute 0..1** scale, because
that is the only reading that is honest for a weight. Erosion's `flow` is in **square metres** and its
`erosion` / `deposition` are in **metres removed or laid down** (`src/pasture_3d_util.cpp:1353` states the
contract). Typed `MASK` they would have rendered solid white — a fictional flow map that looks like a
finished result. Typed `FIELD` they render against their own measured range, with the range shown.

Worked examples from the audit, all decided by reading the producer rather than the name:

* `erosion_hydraulic.sediment` and `.flow` — **MASK**. Both are literally `clamp(x / max, 0, 1)`.
* `stream_extraction.flow_rate` — **MASK**. `clamp(flow / divisor, 0, 1)`, divisor stored.
* `smooth_fill.deposition` — **MASK**. Carries `last_deposition_divisor`, which is the reachable divisor.
* `erosion.flow` / `.erosion` / `.deposition` / `.wetness` — **FIELD**. m² and metres; nothing divides them.
* `path_distance.signed_distance` — **SIGNED**. Zero is the road edge; the sign is the whole point.
* `path_carve.cut` / `.fill` — **MASK**, and this one is a warning: they *sound* like metres. The source
  documents them as [0,1] coverage (`pasture3d_graph_node_path_carve.gd:214`). A name-based guess was wrong
  here. Read the producer.

---

## 5. Choosing a type — the decision, in order

1. **One value per cell, or one value total?** → §2. If it is per-port, it is a value type, and
   `native_param_ports()` must give it a slot.
2. **Is it a resource?** → `PATH`. Is it a bundle? → `TERRAIN_BUS`.
3. **Is it elevation in metres?** → `HEIGHT`.
4. **Can you point at the division into [0,1] and at where the divisor lives?** → `MASK`. If not, keep going.
5. **Can it go negative, and does zero mean something?** → `SIGNED`.
6. Otherwise → `FIELD`.

---

## 6. Connectivity

GraphEdit permits **same-type** wires by itself. **Cross-type** wires exist only where registered, in
`Pasture3DGraphEditor.register_connection_types()` (`project/addons/pasture_3d/src/graph_editor.gd`).

The four scalar field types — `HEIGHT`, `MASK`, `FIELD`, `SIGNED` — are **mutually connectable**. They are one
grid of floats underneath and the type is a reading instruction, so refusing the wire would buy nothing and
cost the author a Reroute node. `PATH` and `TERRAIN_BUS` connect **only to themselves**: a `PATH` wire carries
a resource, so a `HEIGHT` plugged into it would be a null the consumer must defend against on every cell.

**This is where a new type bites you.** A type nobody registers connects to nothing but itself, and the
failure arrives late and looks unrelated — as *"I can't re-make a wire that is already in my graph"*, because
a stored connection is a pair of **indices** and keeps evaluating either way. `GraphPortTypeGate [E]` drives
the real registration function rather than a copy of it, so a type left out is caught at once.

---

## 7. Known rough edge: `VECTOR` as an input

`transform.offset` (port 1) is the **only** `VECTOR` *input* in the registry, and it is inert on **both**
routes: `eval_grid` ignores `p_inputs[1]` and reads the `offset` property, and `native_param_ports()` maps it
to `-1` because a `Vector2` needs two params slots and the map holds one int per port. The wire is drawable
and does nothing.

It is unrepresentable rather than merely unfinished: the graph bus is scalar floats, so a `VECTOR` wire cannot
carry a `Vector2` at all. Fixing it means removing the socket, which **shifts every later port index down by
one and silently rewires existing saved graphs**. That is a migration, not a retype, and it is deliberately
not done here. `GraphPortTypeGate [C]` reports it.

---

## 8. Adding a new type — the four steps

A new `PortType` member is a **four-place** change. Miss any one and the failure is silent.

1. **The enum** — `project/addons/pasture_3d/graph/pasture3d_graph_node.gd`. Append at the end; the value is
   an index into the colour table and into saved data, so **never renumber an existing member**.
2. **The colour** — `PORT_COLORS` in `project/addons/pasture_3d/src/graph_editor.gd`, at the matching index.
   The editor reads `PORT_COLORS[type % size]`, so a missing entry does not error: it **wraps** onto another
   type's colour, and the socket just looks like something it is not.
3. **The connection pairs** — `register_connection_types()`, same file. §6.
4. **The gate** — run `GraphPortTypeGate` and watch it green. `[D]` fails if the colour table fell behind the
   enum; `[E]` fails if the new type connects to nothing.

Then extend `GraphPortTypeAudit`'s `TYPE_NAMES` and `PORT_COLOR_COUNT` so the probe can name it.

---

## 9. The process for a future session

**Do not retype a port from its name.** Every retype in the audit that produced this guide was decided by
reading the C++ or GDScript that *writes* the channel, and one name-based guess was wrong (§4, `path_carve`).

The routine:

```bash
Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphPortTypeAudit.tscn
```

`GraphPortTypeAudit` is a **probe, not a gate**. It prints every port of every registered node as a
tab-separated table and flags only what is mechanically decidable. It asserts nothing about whether a port
carries the *right* type — that is a judgement about what a node produces, and it cannot be made from the
declarations alone.

So: read the table, find the ports that look wrong, **open the producer and read it**, and bring the proposed
retypes **to the user for approval before changing them**. A retype changes how a channel renders and what it
will connect to; it is not a cleanup.

```bash
Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphPortTypeGate.tscn
```

`GraphPortTypeGate` is the gate, and it is in `project/bench/gates.txt`. It holds §2's invariant, §6's
connectivity, and §8's four steps. Every criterion runs a **control that must fail** beside it, because a
criterion that only ever sees healthy data cannot tell "all clear" from "I checked nothing".

---

## 10. Related

* `PASTURE3D_TERRAIN_GRAPH_GUIDE.md` §9 — the editor's port rendering, and the widget/property range drift
  that is the sibling failure mode of this one.
* `PASTURE3D_GRAPH_VISUALIZATION_SPEC.md` §5 — how a declared type chooses a representation. This is what
  makes a mis-typed port a *visible* lie rather than only a bookkeeping error.
* `src/pasture_3d_util.cpp:1353` — the units contract for the erosion channels.
