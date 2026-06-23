# Headless test harness

A small, dependency-free unit-test runner for Godot 4.x projects. It runs **headless** (no editor window),
discovers your test files, and sets a process **exit code** (`0` all passed / `1` any failure) so an agent
or CI step can branch on the result.

## Layout

```
tests/
├── framework/            ← drop-in; copy this folder into any Godot project
│   ├── gd_test.gd        ← class_name GdTest — base class + assertions
│   └── test_runner.gd    ← SceneTree main loop: discovery + run + exit code
├── unit/                 ← your tests live here (any subfolder works)
│   ├── test_framework_selfcheck.gd
│   └── test_pasture3d_smoke.gd
├── run_tests.ps1         ← Windows launcher
├── run_tests.sh          ← Linux/macOS/Git-Bash launcher
└── README.md
```

## Running

Point the launcher at your Godot binary once per shell, then run it:

```powershell
# Windows (PowerShell)
$env:GODOT_BIN = "C:\path\to\Godot_v4.7-stable_win64_console.exe"
./tests/run_tests.ps1
```

```bash
# Linux / macOS / Git-Bash
GODOT_BIN=/path/to/godot ./tests/run_tests.sh
```

> Use the **console** build of Godot on Windows (`..._console.exe`) so stdout reaches the terminal.

Or call Godot directly (what the launchers do under the hood):

```
godot --headless --path <project> --script res://tests/framework/test_runner.gd
```

### Options (pass after a literal `--`)

| Arg | Effect |
| --- | --- |
| `--dir=res://tests/unit` | Limit discovery to a subtree (default `res://tests`) |
| `--filter=detach` | Only run test methods whose name contains the substring |

Through a launcher you can pass them straight: `./run_tests.sh --filter=smoke`.

## Writing a test

Create `tests/unit/test_<thing>.gd`. The file name **must** start with `test_` and end with `.gd`.
Extend `GdTest`; every method named `test_*` is run automatically.

```gdscript
extends GdTest

func test_addition() -> void:
    assert_eq(2 + 2, 4)
    assert_true([1, 2].has(2))

# Optional lifecycle hooks:
func before_all() -> void: pass     # once, before this file's tests
func after_all() -> void: pass      # once, after
func before_each() -> void: pass    # before every test_* method
func after_each() -> void: pass     # after every one
```

Need the live scene tree (to instance a scene/node)? The runner injects it:

```gdscript
func test_with_tree() -> void:
    var n := Node.new()
    scene_tree.get_root().add_child(n)
    assert_true(n.is_inside_tree())
    n.queue_free()
```

### Assertions

`assert_true` · `assert_false` · `assert_eq` · `assert_ne` · `assert_almost_eq(a, b, eps)` ·
`assert_gt` · `assert_lt` · `assert_null` · `assert_not_null` · `fail(msg)`

Each takes an optional trailing `msg`. A method that records **zero** assertions still passes but is
flagged `(warning: 0 assertions)` so accidental no-op tests are visible.

## Reusing in another project (e.g. the main game)

1. Copy `tests/framework/` and the two launcher scripts into the other project's `tests/` folder.
2. Add your own `tests/unit/test_*.gd` files.
3. Set `GODOT_BIN` and run the launcher.

The framework has no Pasture3D (or any project) dependency — only `test_pasture3d_smoke.gd` is
project-specific, so leave it behind.

## Limitation: editor-only code

This runner executes in **non-editor** headless mode, so `Engine.is_editor_hint()` is **false**. Any logic
gated behind that flag early-returns and cannot be exercised here. In Pasture3D that includes the landscape
brush tools (place/undo, `detach_placement`, layer baking) — those stay manually verified in the editor.
What this harness *can* cover: pure logic/geometry helpers, the GDExtension build/registration (see
`test_pasture3d_smoke.gd`), and anything not behind the editor gate. An editor-context runner could be added
later if we need to test the tools themselves automatically.
