# Prompt: review and raise the Particle Hydraulic and ErosionHydraulic graph nodes to Salève/Strata quality

Review the two older hydraulic erosion graph nodes and improve them until their quality matches the Salève
Erosion and Strata nodes. Measure their behaviour against Hesiod's equivalents. Work in phases, and stop for
my approval between the review and the implementation.

## The subjects

| Node | GDScript (editor) | Native | Dev/GD twin | Existing gates |
|---|---|---|---|---|
| Particle Hydraulic | `graph/pasture3d_graph_node_hydraulic_particle.gd` | `src/pasture_3d_hydraulic_particle.cpp/.h` | `graph/pasture3d_graph_node_dev_hydraulic_particle.gd` | `bench/GraphHydraulicParticleGate`, `bench/GraphHydraulicAccelerationGate`, `bench/SolverThreadParityGate`, `bench/GraphGpuParityGate` (sediment share) |
| ErosionHydraulic (grid) | `graph/pasture3d_graph_node_erosion_hydraulic.gd` | `src/pasture_3d_erosion_hydraulic.cpp/.h` | `graph/pasture3d_graph_node_dev_erosion_hydraulic.gd` | same set; find the rest with grep |

The references to match:
- Salève: `src/pasture_3d_hydraulic_saleve.cpp` and `PASTURE3D_SALEVE_STRATA_FIDELITY_SPEC.md`.
- Strata: its node and spec.

Hesiod's counterparts are the hydraulic particle erosion node and the grid/pipe-model hydraulic erosion
node (built on HighMap).

## Hard constraint: GPL

Hesiod and HighMap are GPL. **Never copy, paraphrase line by line, or transliterate their code**, and do not
paste it into this conversation or into the repo.

You may compare these:
- behaviour you observe;
- parameter sets and ranges, and what the documentation says they do;
- the published algorithms the code cites, read from the papers themselves. Examples: Mei et al. 2007 on the
  pipe model; Beyer 2015 and Lague on particle erosion; Št'ava et al. 2008.

Write every implementation from the papers and from first principles. If a comparison would need their
source, describe the behaviour gap instead, and derive our own approach.

## What the Salève/Strata work taught us (apply it to both nodes)

1. **Outputs are metres, and masks come from Float to Mask.**
   - A solver never emits a hidden 0..1 mask or a normalised depth.
   - Every auxiliary channel (eroded, deposited, flow, water) is a physical quantity in metres (or m²/m³ where
     it has to be), documented on the port.
2. **Auxiliary masks must describe the FINAL surface.**
   - Salève's `sediment` was measured before a later stage cut the trenches, so it did not lie in them.
   - Its `eroded_rock` was "input minus output", which counted the relief reshaping of the whole terrain as
     erosion on almost every cell.
   - For each channel, check which stage it is sampled at and what it includes. Then measure it: compare its
     mean in the final height's trenches with its mean elsewhere, against the old reading as a control.
     GraphSaleveDepositionGate [H] is the template.
   - Watch for weights read at the wrong scale. A flatness term read at the settling scale zeroed a whole
     mountain flank.
3. **Metric, not grid fractions.** Salève once used `dx = 1/gw`, so resolution and the brush margin changed
   the drainage network. Check that every length, slope, rate and radius is in world units and that the
   result is invariant to grid resolution. Check it with the same terrain at two resolutions, and to the
   margin.
4. **Margins and outlets.**
   - Salève's margin lift came from outlets on the border only; `outlet_level` fixed it, and subtracting a
     bulk offset afterwards did not.
   - Check how each node treats the grid edge: particles leaving the grid, water draining off, sediment
     piling at the rim.
   - Check the node against the brush's `modifier_margin` skirt. Fixes stay at the rim and never move the
     interior.
5. **Freeze.**
   - Both nodes need native freeze support, with a correct `native_freeze_entry`.
   - The freeze key must hash any unwired port as its `input_unwired_default`, through `key_defaults`.
     Otherwise every freeze hit is stale.
   - Cover all key ports in `freeze_key_grid_ports`.
   - Prove the key is the same across the GDScript, native and worker routes.
6. **Lowering.**
   - Diff each node's `@export`s against `native_lower()`. Strata's `terrace_profile` once shaped `eval_cell`
     but never reached native.
   - Program params are float32; a double-precision solver called through a lowered node drifted 0.06 m after
     25 iterations. Say where precision matters.
   - An op missing from `graph_op_ids()` silently drops the WHOLE graph to GDScript. Check
     `native_supported()`.
   - The native op sees four field inputs; ports from the fifth on drive scalars only.
7. **Parity and threads.**
   - The GDScript twin is the oracle, so C++ must match it. Use a tolerance, plus a control that breaks it.
   - Thread parity needs at least 128 rows, because the pool runs serially on small grids. Prove the split
     happened with `parallel_dispatch_count`.
   - GPU paths: GLSL can flip exact hits by one ulp, and a shared function changes rounding.
8. **Determinism.** Particle erosion is random. Seeds must be fixed, the result must be the same on every
   thread count, and the scatter order must not depend on scheduling. The GPU sediment-share hoist bug in
   GraphGpuParityGate is exactly this class of problem.
9. **Gates.**
   - Every criterion needs a control that fails, and must distinguish "measured nothing" from "measured
     well".
   - Count criteria that completed, not only failures.
   - Assert on what the system produced, not on your own call into the node.
   - `evaluate()` takes the native route, so it is not an oracle.
   - Parse-check every edited GDScript before running it, because a parse error hangs headless.
   - An exit code of 0xC0000005 after PASS is the known engine crash on quit.

## Phase 1: review (read-only, then report and stop)

For each node, produce:
- **An algorithm summary:** what it actually computes, stage by stage, with file:line references.
- **A Hesiod comparison.** Compare the parameter set and what each parameter means, the physical model, the
  outputs and their units, and edge handling. Cover resolution/scale behaviour and typical visual results;
  run both where you can and describe what you see. Also compare which papers each follows. List the
  features Hesiod has that we lack, and the reverse.
- **A defect list** against every lesson above: confirmed bugs, with a failing measurement where possible,
  kept separate from suspicions.
- **Quality gaps against Salève and Strata:** fidelity, controllability, scale invariance, the meaning of the
  aux channels, and freeze/lowering/parity coverage.
- **A ranked improvement plan.** For each item give the expected visual effect, the risk to existing looks
  (tuned scenes must not shift silently), and the gate that will prove it.

Put the review in a single document. Do not change code in this phase. Stop and wait for my approval.

## Phase 2: implementation (after approval)

- Commit each item on its own, with a gate that has a failing control. Check the gate can fail by breaking the
  mechanism, then revert that break.
- Keep the GDScript twin and C++ in step, and keep freeze, lowering, thread and GPU parity green.
- If a change alters a default look, say so and ask before shipping. Prefer a new parameter, with the old
  behaviour as its default, over retuning a scene quietly.
- Remove superseded code outright instead of shimming it.

## Standing rules

- **Never run benchmarks or perf tests without asking.** I run another game engine on this machine.
  Correctness gates are fine.
- **Don't commit my unrelated work-in-progress files.** Check `git status` and stage only your own files;
  don't use `git stash`.
- **Toolchain:**
  - Build from the repo root: `python -m SCons target=template_debug -j8`.
  - Godot is `G:/LaughingRooster/GodotVersions/Godot_v4.7-stable_win64/Godot_v4.7-stable_win64_console.exe`.
  - Parse-check: `--headless --path . --check-only --script res://...`.
  - Run a gate from `project/`: `--headless --path . res://bench/X.tscn`.
- End commit messages with the `Co-Authored-By` line from the session's instructions.
