extends GdTest
## Self-check: proves the harness, every assertion, and the exit-code wiring work. Use this file as a
## template for new test files — copy it, rename to test_<thing>.gd, and replace the methods.

func test_truthy() -> void:
	assert_true(1 + 1 == 2)
	assert_false(1 + 1 == 3, "math still works")

func test_equality() -> void:
	assert_eq(2 + 2, 4)
	assert_ne("a", "b")
	assert_almost_eq(0.1 + 0.2, 0.3, 1e-6, "float tolerance")

func test_ordering() -> void:
	assert_gt(10.0, 1.0)
	assert_lt(1.0, 10.0)

func test_collections() -> void:
	assert_eq([1, 2, 3], [1, 2, 3], "arrays compare element-wise")
	assert_eq({"x": 1, "y": 2}, {"x": 1, "y": 2}, "dicts compare by content")

func test_null_checks() -> void:
	var n: Node = null
	assert_null(n)
	assert_not_null(RefCounted.new())
