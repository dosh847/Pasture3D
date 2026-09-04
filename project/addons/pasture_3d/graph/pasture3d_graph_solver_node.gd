# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphSolverNode — the LIVE/FROZEN freeze protocol, written once.
#
# A SOLVER node is a grid node whose evaluation is expensive enough that re-running it on every graph
# evaluation is not acceptable while authoring: an erosion solve, a DLA growth, a lake fill. Those nodes
# offer the user a choice — LIVE re-solves every time, FROZEN solves once and serves that solve until the
# node's Bake button is pressed — and a stale warning when the inputs moved underneath a frozen solve.
#
# ---- why this class exists ----
#
# That choice is one mechanism, and it was copy-pasted into twenty files: `enum Evaluation { LIVE,
# FROZEN }`, the `_cache` / `_cache_key` / `_dirty_since_bake` / `_stale` quartet, `blocks_native()`,
# `_clear_solver_cache()`, `_set_stale()`, the stale warning string, and an eighteen-line hit-miss flow
# that differed between copies only in which grids went into the key and which arguments went into the
# solve. Twenty copies of one flow is twenty places for it to drift, and it had:
#
#   * Four incompatible key rules (§4.4). Lake Flooding and Stream Extraction hashed only the array, so a
#     frozen solve could not tell 512x128 from 128x512 and served a lake surface computed for the other
#     shape. Fixed in P4 by `Pasture3DGraphNode.solver_cache_key()`, which this class now makes the only
#     reachable route.
#   * Three of the nine [Dev/GD] twins set `_stale` directly instead of calling `_set_stale()`, so the
#     freeze went stale without the inspector's warning list ever refreshing — the warning existed and
#     was never shown.
#   * Nine of the twenty had no `blocks_native()` at all.
#
# The subclass now supplies only what is genuinely its own: WHICH grids the solve depends on, and the
# solve. Everything between those two is here.
#
# ---- what a subclass writes ----
#
#   var key := solver_cache_key(p_gw, p_gh, [surface, hardness])   # its own dependency set
#   return solve_cached(key, func(): return _solve(surface, hardness, p_gw, p_gh, p_rect))
#
# plus, optionally, `bake_label()` for the warning text, `_init()` to default to FROZEN, and
# `_on_cache_hit()` when a cached solve can be adjusted more cheaply than re-solved (DLA rescales its
# amplitude that way).
@tool
class_name Pasture3DGraphSolverNode
extends Pasture3DGraphNode


## LIVE re-solves on every evaluation; FROZEN solves once and serves the cache until the node's Bake
## button is pressed, raising a stale warning when the inputs or parameters changed since.
enum Evaluation { LIVE, FROZEN }

## Which way this solver evaluates. See the enum above.
##
## The default is LIVE, which is the safe answer: a node the user has not thought about re-solves and is
## therefore never wrong, only slow. The eight solvers heavy enough to want FROZEN out of the box set it
## in their own `_init()` — GDScript cannot re-declare an inherited export to change its default.
@export var evaluation: Evaluation = Evaluation.LIVE:
	set(v):
		if evaluation == v:
			return
		evaluation = v
		emit_changed()

# ---- Runtime freeze state (not serialised — the caches rebuild on demand) ----
var _cache: Dictionary = {}        # cache key -> the solved value, at most one entry
var _cache_key: int = 0            # the input hash the cache was solved for
var _dirty_since_bake: bool = false
var _stale: bool = false


## What this node's Bake button says, for the stale warning. Override to match the button's own label.
func bake_label() -> String:
	return "Bake"


## FROZEN means this node serves its own cache, which only the GDScript evaluator can do — the native
## program is a pure function of the graph and has no way to serve or invalidate a cached solve, so a
## frozen node takes the WHOLE graph off the native path. See Pasture3DGraphNode.blocks_native().
func blocks_native() -> bool:
	return evaluation == Evaluation.FROZEN


## Drop the cached solve, so the next evaluation re-solves. This is what the Bake button does.
func _clear_solver_cache() -> void:
	if _cache.is_empty() and not _stale and not _dirty_since_bake:
		return
	_cache.clear()
	_dirty_since_bake = false
	_stale = false
	emit_changed()


## Call from a parameter setter: a frozen solve no longer reflects the parameters, and must say so.
func mark_dirty_since_bake() -> void:
	if not _cache.is_empty():
		_dirty_since_bake = true


func is_stale() -> bool:
	return _stale


func _set_stale(p_stale: bool) -> void:
	if _stale == p_stale:
		return
	_stale = p_stale
	# The warning list changed; refresh it without re-solving (this runs DURING an evaluation).
	if Engine.is_editor_hint():
		emit_changed.call_deferred()


## The stale line, plus whatever the subclass adds. A subclass overriding `node_warnings()` should start
## from `super()` so the freeze warning survives.
func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if _stale:
		w.append("%s is FROZEN and its input or parameters changed since the bake — it is showing the "
			% display_name() + "solve it made for the old shape. Press %s to re-solve." % bake_label())
	return w


## The freeze itself: serve the cache when frozen and warm, solve and keep it when frozen and cold,
## re-solve and hold nothing when live.
##
## `p_key` is the subclass's own dependency set, already reduced by `solver_cache_key()`. `p_solve` is a
## Callable taking no arguments and returning the solved value — an Array of channel grids for the
## multi-output solvers, whatever the node's `eval_grid_channels` contract says. Nothing here inspects it.
func solve_cached(p_key: int, p_solve: Callable) -> Variant:
	if evaluation == Evaluation.FROZEN:
		if not _cache.is_empty():
			# A key change and a parameter change are the two ways a frozen solve goes stale, and both are
			# reported rather than acted on: re-solving here would defeat the freeze, which is the point.
			if _dirty_since_bake or p_key != _cache_key:
				_set_stale(true)
			return _on_cache_hit(_cache[_cache_key])
		var solved: Variant = p_solve.call()
		_cache = {p_key: solved}
		_cache_key = p_key
		_dirty_since_bake = false
		_set_stale(false)
		return solved

	# LIVE. Drop anything a previous freeze left, so switching back to FROZEN re-solves rather than
	# serving a cache made before the parameters moved.
	if not _cache.is_empty():
		_cache.clear()
	_set_stale(false)
	return p_solve.call()


## Last chance to adjust a served cache. The default serves it unchanged; DLA overrides this to rescale
## the cached height by its amplitude, which is exact and far cheaper than re-growing the massif.
func _on_cache_hit(p_cached: Variant) -> Variant:
	return p_cached
