@tool
class_name GdTest
extends RefCounted
## Base class for headless tests. Subclass it, add methods named `test_*`, and put `assert_*` calls inside
## them. The runner (test_runner.gd) discovers every `test_*.gd` under the tests dir, runs each `test_*`
## method, and reports pass/fail with a process exit code. Optional lifecycle hooks you can override:
## before_all/after_all (once per file) and before_each/after_each (around every method).
##
## DROP-IN: this folder (tests/framework) has NO project dependencies — copy it into any Godot 4.x project.
## See tests/README.md.

## SceneTree handle, injected by the runner, so a test can add nodes (e.g. instance a scene under
## `scene_tree.get_root()`) when it needs the live tree. Pure-logic tests can ignore it.
var scene_tree: SceneTree = null

## Failures recorded for the CURRENT test method (the runner resets this before each one).
var _failures: PackedStringArray = PackedStringArray()
## Assertions evaluated in the current method — a test that ran zero assertions is reported as suspicious.
var _asserts: int = 0


## Called by the runner before each test method to reset per-method state.
func _begin_method() -> void:
	_failures = PackedStringArray()
	_asserts = 0


# ---- Lifecycle hooks (override as needed; default no-ops) ----
func before_all() -> void: pass
func after_all() -> void: pass
func before_each() -> void: pass
func after_each() -> void: pass


# ---- Assertions ----
func assert_true(cond: bool, msg: String = "") -> void:
	_asserts += 1
	if not cond:
		_record("assert_true failed", msg)

func assert_false(cond: bool, msg: String = "") -> void:
	_asserts += 1
	if cond:
		_record("assert_false failed", msg)

func assert_eq(actual: Variant, expected: Variant, msg: String = "") -> void:
	_asserts += 1
	if not _equal(actual, expected):
		_record("expected %s == %s" % [str(expected), str(actual)], msg)

func assert_ne(actual: Variant, other: Variant, msg: String = "") -> void:
	_asserts += 1
	if _equal(actual, other):
		_record("expected %s != %s" % [str(actual), str(other)], msg)

func assert_almost_eq(actual: float, expected: float, eps: float = 1e-4, msg: String = "") -> void:
	_asserts += 1
	if absf(actual - expected) > eps:
		_record("expected %f ≈ %f (±%g)" % [actual, expected, eps], msg)

func assert_gt(a: float, b: float, msg: String = "") -> void:
	_asserts += 1
	if not (a > b):
		_record("expected %s > %s" % [str(a), str(b)], msg)

func assert_lt(a: float, b: float, msg: String = "") -> void:
	_asserts += 1
	if not (a < b):
		_record("expected %s < %s" % [str(a), str(b)], msg)

func assert_null(v: Variant, msg: String = "") -> void:
	_asserts += 1
	if v != null:
		_record("expected null, got %s" % str(v), msg)

func assert_not_null(v: Variant, msg: String = "") -> void:
	_asserts += 1
	if v == null:
		_record("expected non-null", msg)

## Unconditional failure (e.g. an unreachable branch was reached).
func fail(msg: String) -> void:
	_record("fail()", msg)


# ---- internals ----
func _record(what: String, msg: String) -> void:
	_failures.append(what + ((" — " + msg) if msg != "" else ""))

## Equality used by assert_eq/ne. `==` in GDScript deep-compares Arrays and Dictionaries element-wise, so
## this works for primitives and collections alike.
func _equal(a: Variant, b: Variant) -> bool:
	return a == b
