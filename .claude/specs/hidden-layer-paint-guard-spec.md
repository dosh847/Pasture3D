# Implementation Spec — Guard Against Painting/Sculpting on a Hidden Layer

Project: Pasture3D (Terrain3D fork, Godot 4.6, GDExtension C++).
Branch context: `pasture3d-layers` (layers feature complete, phases 1–7).
Spec type: design document only — **no source changes are part of this spec.**

---

## 1. Problem statement

The non-destructive layers system lets each `Pasture3DLayer` be shown or hidden via a
visibility toggle. Sculpt/Height tools write to the **active** layer.

- **Current behavior:** A stroke applies to the active height layer even when that layer
  is hidden (`is_visible() == false`). The user edits geometry they cannot see — confusing
  and error-prone. The compositor *does* skip hidden layers when rebuilding the region
  image (`pasture_3d_data.cpp:1095`), so the edit is written into the layer tiles but does
  **not** appear in the viewport — i.e. the edit silently "vanishes," yet still mutates the
  layer and creates an undo entry.
- **Desired behavior:** If the active (target) layer is hidden, the sculpt/paint stroke
  must **not apply any changes**, must **not create an undo entry**, and the editor must
  **warn the user noticeably** that they tried to paint on a hidden layer.

---

## 2. Current behavior analysis (with file:line references)

### 2.1 Layer visibility storage / toggle

- Visibility is a serialized bool on the layer.
  - `src/pasture_3d_layer.h:93-94` — `set_visible(bool)`, `bool is_visible() const { return _visible; }`.
  - Bound to script + exposed as a property: `src/pasture_3d_layer.cpp:432` (`is_visible`)
    and `:472` (`"visible"` property `set_visible`/`is_visible`).
- Toggled from the Layers dock per-row `CheckButton`:
  - `project/addons/pasture_3d/src/layers_dock.gd:166-170` builds the visibility toggle;
  - `:230-238` `_on_visible()` calls `layer.set_visible(v)` then `recomposite_layer(p_idx)`.
- The compositor already honors visibility (skips hidden layers), confirming a hidden
  layer's edits are invisible in the viewport:
  - Height: `src/pasture_3d_data.cpp:1095` — `if (!layer || !layer->is_visible() || layer->get_map_type() != TYPE_HEIGHT) continue;`
  - Control: `src/pasture_3d_data.cpp:1158`; Color: `src/pasture_3d_data.cpp:1192`.

### 2.2 Which layer is the active / target layer

- The active layer index lives on the stack: `Pasture3DLayerStack::get_active_layer()` /
  `set_active_layer()` (used throughout `layers_dock.gd`, e.g. `:139`, `:218-221`).
- The editor resolves the active height layer at stroke start:
  - `src/pasture_3d_editor.cpp:1006-1007`
    ```cpp
    Ref<Pasture3DLayerStack> stack = _terrain->get_data()->get_layer_stack();
    Ref<Pasture3DLayer> active = stack.is_valid()
        ? stack->get_layer(stack->get_active_layer()) : Ref<Pasture3DLayer>();
    ```

### 2.3 Where a brush stroke gets applied (the commit point and the routing decision)

The relevant flow, all in `src/pasture_3d_editor.cpp`:

1. **Stroke start (mouse-down, once per stroke):** `start_operation()` —
   `src/pasture_3d_editor.cpp:998-1019`. This is where the editor decides whether the
   stroke routes to a layer and captures the target into `_stroke_layer`. Called once per
   click from `editor_plugin.gd:267` (`editor.start_operation(...)`), immediately followed
   by `editor.operate(...)` on `:268`.

   ```cpp
   _stroke_blocked = false;
   _stroke_layer = Ref<Pasture3DLayer>();
   ...
   if ((_tool == SCULPT || _tool == HEIGHT) && _terrain->get_data()->is_layer_routing()) {
       ... active = stack->get_layer(stack->get_active_layer());
       if (active.is_valid() && active->get_map_type() == TYPE_HEIGHT) {
           if (active->is_locked() || active->is_reserved()) {   // <-- existing guard
               _stroke_blocked = true;
               _notify_layer_blocked(active);
           } else {
               _stroke_layer = active;
           }
       }
   }
   ```

   **This is the exact insertion point for the hidden-layer guard.** The current `if`
   checks `is_locked()`/`is_reserved()` but **not** `is_visible()` — that omission is the bug.

2. **Per-move application:** `operate()` — `src/pasture_3d_editor.cpp:1022-1051`. It already
   short-circuits a blocked stroke:
   - `:1028-1030`
     ```cpp
     if (_stroke_blocked) {
         return; // Active layer is locked/reserved; the whole stroke is swallowed (warning already flashed).
     }
     ```
   So once `_stroke_blocked` is set in `start_operation`, **no pixels are written** for any
   frame of the drag. The actual pixel write happens later at
   `src/pasture_3d_editor.cpp:566` (`_stroke_layer->set_sample(...)`), which is never reached
   when `_stroke_blocked` is true.

3. **Stroke end / undo:** `stop_operation()` — `src/pasture_3d_editor.cpp:1072-1111`. Undo is
   only stored when regions/locations were actually edited:
   - `:1077` `if (_is_operating && (!_added_removed_locations.is_empty() || !_edited_regions.is_empty()))`.
   A blocked stroke writes nothing, so `_edited_regions` stays empty and `_store_undo()`
   (`:1098`) is never called. **A blocked stroke therefore already creates no undo entry** —
   this satisfies the undo requirement for free, provided the guard sets `_stroke_blocked`
   at `start_operation` (the same way locked/reserved does).

### 2.4 Existing user-facing warning mechanism

The project already has a purpose-built warning path for the locked/reserved case — reuse it:

- C++ helper: `Pasture3DEditor::_notify_layer_blocked()` —
  `src/pasture_3d_editor.cpp:624-630`. It logs `LOG(WARN, ...)` and, if the plugin exposes
  `flash_layer_warning`, calls it with the layer name:
  ```cpp
  Object *plugin = _terrain ? _terrain->get_plugin() : nullptr;
  if (plugin && plugin->has_method("flash_layer_warning")) {
      plugin->call("flash_layer_warning", p_layer->get_layer_name());
  }
  ```
  Declared at `src/pasture_3d_editor.h:107-108`.
- Plugin bridge: `editor_plugin.gd:175-177`
  ```gdscript
  func flash_layer_warning(p_name: String) -> void:
      if layers_dock:
          layers_dock.flash_warning(p_name)
  ```
- Dock UI: `project/addons/pasture_3d/src/layers_dock.gd:113-116` `flash_warning()` shows a
  red `Label` (`_warning`, color `#FC7F7F`, `layers_dock.gd:55-64`) for 2.5 s via a one-shot
  `Timer`. The text is currently hard-coded:
  ```gdscript
  _warning.text = "Layer '%s' is locked or reserved — stroke blocked" % p_layer_name
  ```

This dock-label flash is the established, in-project warning mechanism. **Use it** rather
than introducing `EditorToaster`/`push_warning`, to stay consistent. (`push_warning`/`LOG(WARN)`
go to the Output/console only and are not "noticeable" enough on their own; they can remain
as the secondary log line that `_notify_layer_blocked` already emits.)

The one shortcoming: the hard-coded message says "locked or reserved," which is wrong for a
hidden layer. The spec below distinguishes the two reasons.

---

## 3. Proposed solution / design

### 3.1 Where the check goes

Insert the visibility check **in `start_operation` alongside the existing locked/reserved
check** (`src/pasture_3d_editor.cpp:1010-1016`). This is the single mouse-down entry point,
so the guard naturally fires **once per stroke**, not per drag frame. Setting
`_stroke_blocked = true` reuses the existing swallow at `operate()` (`:1028`) so **no pixels
are written** and (per §2.3.3) **no undo entry is created**.

Recommended ordering of reasons (hidden checked together with locked/reserved). A hidden
layer should block regardless of lock state. Suggested combined condition:

```cpp
if (active.is_valid() && active->get_map_type() == TYPE_HEIGHT) {
    if (!active->is_visible()) {
        _stroke_blocked = true;
        _notify_layer_blocked(active, BLOCK_HIDDEN);
    } else if (active->is_locked() || active->is_reserved()) {
        _stroke_blocked = true;
        _notify_layer_blocked(active, BLOCK_LOCKED);
    } else {
        _stroke_layer = active;
    }
}
```

(`BLOCK_HIDDEN`/`BLOCK_LOCKED` is one way to convey the reason; see §3.3 for the
message-routing options.)

### 3.2 Short-circuiting so NO changes apply

No new short-circuit logic is required. `_stroke_blocked` already:
- causes `operate()` to `return` before any `set_sample`/region write (`:1028-1030`);
- leaves `_edited_regions` empty so `stop_operation()` skips `_store_undo()` (`:1077-1098`).

The guard only needs to set `_stroke_blocked = true` (and not set `_stroke_layer`) at
`start_operation`, exactly as the locked/reserved branch does today.

### 3.3 Surfacing the warning (once per stroke, distinct message)

Because the warning is fired from `_notify_layer_blocked`, which is only reached from
`start_operation` (once per mouse-down), it is **already debounced to once per stroke**. No
per-frame spam is possible. Do not move the warning into `operate()`.

To give a correct, distinct message for the hidden case, extend the warning path to carry a
reason. Two acceptable approaches (pick one; **Option A preferred** for minimal surface area):

**Option A — pass a reason to the existing plumbing.**
1. Change `_notify_layer_blocked(const Ref<Pasture3DLayer> &)` to also take a reason (enum or
   `String`): `src/pasture_3d_editor.h:108`, `src/pasture_3d_editor.cpp:624`.
2. Forward the reason through `flash_layer_warning(name, reason)` in `editor_plugin.gd:175`.
3. In `layers_dock.gd:113` `flash_warning(name, reason)`, choose the message:
   - hidden → `"Layer '%s' is hidden — stroke blocked. Show the layer to paint on it." % name`
   - locked/reserved → existing text.

**Option B — keep signatures, branch in C++.** Build the full message string in
`_notify_layer_blocked` based on `is_visible()`/`is_locked()`/`is_reserved()` of the passed
layer and pass the finished string to `flash_layer_warning`. This changes
`flash_warning`/`flash_layer_warning` to accept a ready message instead of a name. Slightly
more churn in GDScript but keeps the reason logic in one place (C++).

Either way, keep the secondary `LOG(WARN, ...)` line in `_notify_layer_blocked` (update its
text to reflect the reason).

---

## 4. Detailed implementation steps (ordered)

1. **C++ — add the visibility branch in `start_operation`.**
   File: `src/pasture_3d_editor.cpp`, function `start_operation`, lines ~1010-1016. Add an
   `!active->is_visible()` branch *before* the locked/reserved branch (see §3.1). Set
   `_stroke_blocked = true` and call the warning helper with a "hidden" reason. Do **not**
   set `_stroke_layer`.

2. **C++ — extend the warning helper to convey the reason (Option A) or build the message
   (Option B).**
   - Header: `src/pasture_3d_editor.h:108` — update the `_notify_layer_blocked` signature.
   - Impl: `src/pasture_3d_editor.cpp:624-630` — update the `LOG(WARN, ...)` text and the
     `plugin->call("flash_layer_warning", ...)` arguments.

3. **GDScript — bridge.**
   File: `project/addons/pasture_3d/src/editor_plugin.gd:175-177` — update
   `flash_layer_warning` to accept/forward the extra reason or message argument.

4. **GDScript — dock message.**
   File: `project/addons/pasture_3d/src/layers_dock.gd:113-116` — update `flash_warning` to
   set a reason-specific message. For the hidden case use wording that tells the user how to
   recover (e.g. "Layer 'X' is hidden — stroke blocked. Make it visible to paint."). Keep the
   red label + 2.5 s timer as-is.

5. **(No change needed)** Confirm `operate()` swallow (`:1028`) and `stop_operation()` undo
   gate (`:1077`) are unmodified — they already handle "blocked ⇒ no write ⇒ no undo."

6. **Docs.** Update `PASTURE3D_LAYERS_GUIDE.md` (the §6/§10.x routing notes) to mention that
   a hidden active height layer now blocks strokes, mirroring locked/reserved. (Optional but
   consistent with the project's habit of documenting each behavior in the guide.)

### Layer (which side: C++ vs GDScript)

The **core guard belongs in C++** (`src/pasture_3d_editor.cpp` `start_operation`), because
that is where stroke routing, `_stroke_blocked`, and the existing locked/reserved guard live,
and it is the only place that runs once per mouse-down with `_stroke_layer` resolution. The
**warning text/UI stays in GDScript** (`editor_plugin.gd` + `layers_dock.gd`), reusing the
existing `flash_layer_warning` → `flash_warning` chain. So: **both**, but the behavioral
change is C++ and the GDScript change is presentation only.

---

## 5. Edge cases

- **Active layer is the Base (index 0).** The Base is dense and always visible in practice;
  `layers_dock.gd:148` disables Remove on Base but visibility can technically be toggled. The
  guard uses the same `is_visible()` check, so a hidden Base also blocks — acceptable and
  consistent. (If product wants the Base to be unhideable, that's a separate dock-UI change;
  not required here.) Note also that when there is no multi-layer stack
  (`is_layer_routing() == false`, `start_operation:1005`), routing is off entirely and there
  is no "hidden layer" concept — plain terrains are unaffected. This is correct: the guard
  only runs inside the `is_layer_routing()` block.

- **Multiple selected layers.** The stack model has a single active index
  (`get_active_layer()`), not a multi-selection. No multi-select handling is needed; the
  guard targets the single active layer. If multi-select is added later, the guard should run
  against whichever single layer the stroke would write to.

- **Brush preview / cursor still showing.** The decal/brush cursor is rendered independently
  of stroke application; it will keep following the mouse over a hidden layer. That is fine —
  the user still sees where they *would* paint. The warning explains why nothing happens.
  (No requirement to suppress the cursor; suppressing it is out of scope.)

- **Control / color layers.** `start_operation` only captures a **TYPE_HEIGHT** active layer
  (`:1010`); a control/color active layer is not a height-edit target and the stroke falls
  through to the legacy region-write path. This spec scopes the guard to the height sculpt
  route (the only editor paint route that exists today — §10.7 follow-ups note there is no
  editor paint route for control/color yet). If/when a control/color paint route is added, an
  equivalent `is_visible()` guard should be added at its stroke-start.

- **Undo interaction.** A blocked stroke writes nothing, so `_edited_regions` stays empty and
  `stop_operation()` (`:1077`) never calls `_store_undo()` — **no undo entry is created.** This
  is exactly the behavior the parallel per-stroke-undo spec requires: a blocked stroke must
  not push an undo action. No coordination code is needed beyond not setting `_stroke_layer`.

- **Toggling visibility mid-drag.** The reason is captured at mouse-down only. If the user
  somehow toggles visibility during a drag (not normally reachable while dragging in the
  viewport), the stroke keeps its mouse-down decision. Acceptable; the dock is not interactable
  mid-viewport-drag in practice.

---

## 6. Testing / verification plan

### 6.1 Manual (in-editor) — primary, mirrors the project's per-phase editor-verify habit
1. Open `project/demo/sculpting_demo.tscn` (or any scene with a `Pasture3D` node that has a
   multi-layer stack so `is_layer_routing()` is true; add a layer via the dock if needed).
2. Add a height layer, make it active, and **hide it** (visibility CheckButton off).
3. Select the Sculpt or Height tool and drag a stroke over the terrain.
   - **Expect:** terrain does not change; the dock shows the red warning label
     ("Layer 'X' is hidden — stroke blocked …") for ~2.5 s; Output log shows a single
     `WARN` line for the stroke.
   - Press Ctrl+Z: **expect nothing to undo** for that blocked stroke (no spurious undo step).
4. **Show** the same layer (visibility on) and drag a stroke.
   - **Expect:** terrain deforms normally; warning does not appear; undo removes the stroke.
5. Drag-and-hold a long stroke over a hidden layer.
   - **Expect:** the warning flashes **once** (not once per frame), confirming the once-per-
     stroke debounce.
6. Regression: on a **plain terrain** (Base-only, `is_layer_routing()` false), sculpting
   still works unchanged (no warning, edits apply).
7. Regression: a **locked** (but visible) layer still blocks with the existing
   "locked or reserved" message.

### 6.2 Automated (headless unit test) — secondary
Add a `test_layer_hidden_stroke_guard` to `src/unit_testing.{h,cpp}` (re-commented invocation
from `Pasture3D` `NOTIFICATION_READY` in `src/pasture_3d.cpp`, matching the existing
`test_layer_*` pattern). Because `start_operation`/`operate` require an editor/plugin and a
live viewport, prefer testing at the data/guard level:
- Build a stack with a hidden active height layer; assert that a simulated stroke routing
  decision yields "blocked" (e.g. expose/verify via the same predicate the guard uses:
  active `is_visible()==false ⇒ blocked`), that the layer's tiles are unchanged after a
  blocked attempt, and that a visible layer is not blocked.
- If a full editor stroke cannot be driven headless, document that the behavioral guard is
  covered by the manual plan §6.1 (consistent with how phases 5–7 were "editor-verified").

Run headless via Godot 4.6.2 as the other layer tests are (per the layers memory: build with
`python -m SCons`, run the suite from the `NOTIFICATION_READY` hook).

---

## 7. Summary of the fix location

- **Guard:** `src/pasture_3d_editor.cpp`, `start_operation()` (~lines 1010-1016) — add a
  `!active->is_visible()` branch next to the existing `is_locked()/is_reserved()` check; set
  `_stroke_blocked = true`, do not set `_stroke_layer`. Everything downstream
  (`operate()` swallow at :1028, `stop_operation()` undo gate at :1077) already produces
  "no changes, no undo."
- **Warning:** reuse the existing `_notify_layer_blocked` (`pasture_3d_editor.cpp:624`) →
  `editor_plugin.gd:175 flash_layer_warning` → `layers_dock.gd:113 flash_warning` red-label
  flash, extended to show a hidden-specific message. This is the project's established,
  noticeable warning mechanism — no new toaster/popup needed.
