# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphNodeCachingGate — Milestone 1 per-node output buffer caching & selective dirty invalidation.
#
# The claim:
# 1. Warm evaluations match cold evaluations with bit-level parity (max diff == 0.0 m).
# 2. Downstream parameter edits (e.g., Terrace / Remap / Blend) skip upstream nodes in 0.0 ms.
# 3. Upstream parameter edits cascade dirty invalidation to all downstream dependents.
# 4. Downstream slider scrubbing on a multi-node graph executes in < 4.0 ms per iteration.
#    (This line said 3.0 while the code has always enforced 4.0. The ENFORCED value is unchanged;
#     the prose is what was wrong. Measured 3.0-3.1 ms, so the margin here is thin on purpose.)
# 5. clear_cache() and max_cache_bytes LRU eviction maintain cache safety and memory bounds.
# House discipline throughout: every test verifies its claim and carries a moving control.
extends Node

const GW := 64
const GH := 64
const RECT := Rect2(-30.0, -30.0, 60.0, 60.0)
const EPS := 1.0e-6

## Node slots in _create_test_pipeline. NAMED, because these were written out as g.nodes[2] and the
## day a barrier node was inserted ahead of Terrace they silently addressed the wrong node: the
## "terrace hardness edit" set a property on a node that has none, and the control went dead.
const IDX_NOISE := 0
const IDX_SMOOTH := 1
const IDX_TERRACE := 2
const IDX_OUTPUT := 3

var _fail := 0


func _ready() -> void:
	print("=== GraphNodeCachingGate: Per-Node Buffer Caching & Selective Invalidation (Milestone 1) ===\n")
	_assert_gdscript_path()
	_a_bit_level_parity()
	_b_selective_downstream_reevaluation()
	_c_upstream_invalidation_cascading()
	_d_slider_scrub_performance()
	_e_cache_eviction_and_memory_limits()
	_f_solver_eviction_frees_measured_bytes()
	_g_a_frozen_graph_modifier_knows_where_it_is()
	_h_a_solver_key_carries_its_dimensions()
	_i_the_native_path_keys_on_the_graph()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH NODE CACHING PASS" if _fail == 0 else "GRAPH NODE CACHING FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# --- A. Cold vs Cached Bit-Level Parity ----------------------------------------------------------------
func _a_bit_level_parity() -> void:
	print("[A] cold vs cached evaluation bit-level parity")
	var g := _create_test_pipeline(10.0, 2, 2.0, 0.8)
	
	# Cold evaluation (populates cache)
	var cold_eval := g.evaluate(GW, GH, RECT)
	
	# Warm cached evaluation (reads cached output)
	var warm_eval := g.evaluate(GW, GH, RECT)
	
	var d := _max_abs_diff(cold_eval, warm_eval)
	print("    max |cold - warm| = %.8f m (want == 0.0)" % d)
	if d > 0.0:
		_fail += 1; print("    !! cached evaluation diverged from cold evaluation")
		
	# CONTROL: an un-cached graph with different params produces a different field (> 0.05 m)
	var g_alt := _create_test_pipeline(20.0, 2, 2.0, 0.8)
	var alt_eval := g_alt.evaluate(GW, GH, RECT)
	var moved := _max_abs_diff(cold_eval, alt_eval)
	print("    control: modified pipeline moves field by %.3f m (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! control dead: pipeline modification did not alter field")


# --- B. Selective Re-Evaluation (Downstream Edit Skips Upstream) --------------------------------------
func _b_selective_downstream_reevaluation() -> void:
	print("[B] downstream edit re-evaluates dirty nodes and reuses clean upstream cache")
	var g := _create_test_pipeline(10.0, 3, 2.0, 0.5)
	
	# 1. Warm the pipeline
	var _v1 := g.evaluate(GW, GH, RECT)
	
	var noise_node: Pasture3DGraphNode = g.nodes[IDX_NOISE]
	var smooth_node: Pasture3DGraphNode = g.nodes[IDX_SMOOTH]
	var terrace_node: Pasture3DGraphNode = g.nodes[IDX_TERRACE]
	
	var noise_cached_grid_prev := noise_node.get_cached_grid()
	var smooth_cached_grid_prev := smooth_node.get_cached_grid()
	
	# 2. Mutate downstream Terrace node
	terrace_node.set("hardness", 0.95)
	
	# 3. Evaluate again
	var v2 := g.evaluate(GW, GH, RECT)
	
	# Verify upstream nodes did NOT recalculate (cached buffer references preserved)
	# Non-empty FIRST. Comparing two empty buffers is true for the wrong reason, and that is exactly how
	# this check passed while the upstream nodes were never being cached at all.
	var cached_populated := not noise_cached_grid_prev.is_empty() and not smooth_cached_grid_prev.is_empty()
	print("    upstream buffers actually populated = %s (want true)" % cached_populated)
	if not cached_populated:
		_fail += 1; print("    !! upstream nodes hold no cached buffer, so 'reused' below means nothing")
	var noise_reused := cached_populated and (noise_node.get_cached_grid() == noise_cached_grid_prev)
	var smooth_reused := cached_populated and (smooth_node.get_cached_grid() == smooth_cached_grid_prev)
	print("    upstream noise cached buffer reused = %s" % noise_reused)
	print("    upstream smooth cached buffer reused = %s" % smooth_reused)
	if not noise_reused or not smooth_reused:
		_fail += 1; print("    !! upstream nodes were re-evaluated when only downstream node was modified")
		
	# Verify output matches a fresh cold evaluation with the same parameters
	var g_fresh := _create_test_pipeline(10.0, 3, 2.0, 0.95)
	var fresh_eval := g_fresh.evaluate(GW, GH, RECT)
	var diff_fresh := _max_abs_diff(v2, fresh_eval)
	print("    max |selective_eval - fresh_cold_eval| = %.8f m (want < %.6f)" % [diff_fresh, EPS])
	if diff_fresh > EPS:
		_fail += 1; print("    !! selective re-evaluation did not match fresh cold evaluation")
		
	# CONTROL: output actually changed from before editing terrace
	var diff_prev := _max_abs_diff(v2, _v1)
	print("    control: terrace hardness change moved output by %.3f m (want > 0.05)" % diff_prev)
	if diff_prev <= 0.05:
		_fail += 1; print("    !! control dead: terrace edit did not change field")


# --- C. Upstream Invalidation Cascading ---------------------------------------------------------------
func _c_upstream_invalidation_cascading() -> void:
	print("[C] upstream edit cascades dirty invalidation to all downstream dependents")
	var g := _create_test_pipeline(10.0, 2, 2.0, 0.8)
	var v1 := g.evaluate(GW, GH, RECT).duplicate()
	
	# Mutate root Noise amplitude
	var noise_node: Pasture3DGraphNode = g.nodes[IDX_NOISE]
	noise_node.set("amplitude", 30.0)
	
	var v2 := g.evaluate(GW, GH, RECT)
	
	# Verify output matches fresh cold evaluation with amplitude 30.0
	var g_fresh := _create_test_pipeline(30.0, 2, 2.0, 0.8)
	var v_ref := g_fresh.evaluate(GW, GH, RECT)
	var d := _max_abs_diff(v2, v_ref)
	print("    max |cascaded_eval - fresh_cold_eval| = %.8f m (want < %.6f)" % [d, EPS])
	if d > EPS:
		_fail += 1; print("    !! upstream invalidation failed to cascade correctly to downstream nodes")
		
	# CONTROL: output moved substantially
	var moved := _max_abs_diff(v2, v1)
	print("    control: 3x noise amplitude moved output by %.3f m (want > 0.05)" % moved)
	if moved <= 0.05:
		_fail += 1; print("    !! control dead: upstream change did not modify output")


# --- D. Slider Scrubbing Performance (< 4.0 ms) -------------------------------------------------------
func _d_slider_scrub_performance() -> void:
	print("[D] downstream slider scrubbing throughput (< 4.0 ms per iteration)")
	# Build realistic 64x64 graph with heavy Noise + 4-pass Smooth + Terrace + Output
	var bench_gw := 64
	var bench_gh := 64
	var g := _create_test_pipeline(15.0, 4, 3.0, 0.5)
	
	# Cold evaluation
	var t0_cold := Time.get_ticks_usec()
	var _cold := g.evaluate(bench_gw, bench_gh, RECT)
	var cold_us := Time.get_ticks_usec() - t0_cold
	var cold_ms := float(cold_us) / 1000.0
	
	# Warmup step
	var terrace_node: Pasture3DGraphNode = g.nodes[IDX_TERRACE]
	terrace_node.set("hardness", 0.55)
	var _warmup := g.evaluate(bench_gw, bench_gh, RECT)
	
	# Simulate 20 continuous slider scrub steps on downstream Terrace
	var scrub_times_us: Array[int] = []
	for i in range(20):
		var val := 0.1 + float(i) * 0.04
		terrace_node.set("hardness", val)
		var t0_scrub := Time.get_ticks_usec()
		var _res := g.evaluate(bench_gw, bench_gh, RECT)
		var dt_us := Time.get_ticks_usec() - t0_scrub
		scrub_times_us.append(dt_us)
		
	var total_warm_us := 0
	for t in scrub_times_us:
		total_warm_us += t
	var avg_warm_ms := (float(total_warm_us) / float(scrub_times_us.size())) / 1000.0
	var speedup := cold_ms / maxf(avg_warm_ms, 0.001)
	
	print("    cold bake time: %.2f ms" % cold_ms)
	print("    avg warm scrub time: %.2f ms (want < 4.0 ms, speedup %.1fx)" % [avg_warm_ms, speedup])
	if avg_warm_ms >= 4.0:
		_fail += 1; print("    !! slider scrub time exceeded 4.0 ms threshold")
		
	# CONTROL: cold evaluation of all steps would take > 2x longer
	if speedup < 2.0:
		_fail += 1; print("    !! caching speedup insufficient (expected >= 2.0x)")




# --- E. Cache Eviction and Memory Limits ---------------------------------------------------------------
func _e_cache_eviction_and_memory_limits() -> void:
	print("[E] cache eviction and memory management")
	var g := _create_test_pipeline(10.0, 2, 2.0, 0.8)
	g.evaluate(GW, GH, RECT)
	
	var bytes_before := g.get_total_cache_bytes()
	print("    total cached bytes populated: %d bytes (want > 0)" % bytes_before)
	if bytes_before <= 0:
		_fail += 1; print("    !! get_total_cache_bytes reported zero with populated caches")
		
	# Test explicit clear_cache()
	g.clear_cache()
	var bytes_after_clear := g.get_total_cache_bytes()
	print("    total cached bytes after clear_cache: %d bytes (want == 0)" % bytes_after_clear)
	if bytes_after_clear != 0:
		_fail += 1; print("    !! clear_cache did not reset all cached buffers to 0")
		
	# Test max_cache_bytes LRU eviction
	# A single 64x64 grid is 64 * 64 * 4 = 16384 bytes.
	# Set limit to 20000 bytes (room for ~1 grid only), forcing eviction of earlier nodes.
	g.max_cache_bytes = 20000
	g.evaluate(GW, GH, RECT)
	var bytes_under_limit := g.get_total_cache_bytes()
	print("    cached bytes under 20KB budget: %d bytes (want <= 20000)" % bytes_under_limit)
	if bytes_under_limit > 20000:
		_fail += 1; print("    !! memory limit eviction failed to keep total cache within max_cache_bytes")
		
	# CONTROL: with large memory limit (default 256MB), all nodes remain cached
	g.max_cache_bytes = 268435456
	g.evaluate(GW, GH, RECT)
	var bytes_unlimited := g.get_total_cache_bytes()
	print("    control: unlimited cache stores all nodes: %d bytes (want > 20000)" % bytes_unlimited)
	if bytes_unlimited <= 20000:
		_fail += 1; print("    !! control dead: multi-node pipeline failed to cache all nodes under 256MB")


# --- F. Evicting a SOLVER node frees the bytes eviction measures (P4 §4.1) ---------------------------
#
# [E] above uses Noise / Smooth / Terrace, none of which override `clear_cache()`, so it never touched
# the defect. All twenty SOLVER nodes did override it, each clearing only its own private `_cache` and
# none calling `super` — so the base `_cached_grid`, which is exactly what `get_cache_size_bytes()`
# measures, survived. Eviction freed zero measured bytes, the `<= max_cache_bytes` break never fired,
# and the loop went on to clear every node in the graph, destroying frozen solves as it went.
func _f_solver_eviction_frees_measured_bytes() -> void:
	print("[F] clearing a solver node frees the bytes get_total_cache_bytes() counts (§4.1)")
	var n := Pasture3DGraphNodeRegistry.create(&"erosion")
	if n == null:
		_fail += 1; print("    !! could not create an Erosion node")
		return
	# store_cache is what the evaluator calls for EVERY node in the eval order, solver or not — which is
	# why a solver really does hold a base buffer its own override could not reach.
	var grid := PackedFloat32Array(); grid.resize(GW * GH)
	n.store_cache(grid, {1: grid.duplicate()}, 12345, 1)
	var before := n.get_cache_size_bytes()
	print("    solver cache after store_cache: %d bytes (want > 0)" % before)
	if before <= 0:
		_fail += 1; print("    !! fixture dead: store_cache left nothing to free")
		return
	n.clear_cache()
	var after := n.get_cache_size_bytes()
	print("    after clear_cache: %d bytes (want == 0)" % after)
	if after != 0:
		_fail += 1; print("    !! a solver override skipped the base buffer reset — eviction frees nothing")
	# CONTROL: the same call on a node with no override has always worked, so a `get_cache_size_bytes`
	# that simply returned 0 would pass the line above for the wrong reason.
	var plain := Pasture3DGraphNodeRegistry.create(&"noise")
	plain.store_cache(grid, {}, 1, 1)
	var plain_before := plain.get_cache_size_bytes()
	plain.clear_cache()
	print("    control: a non-solver node measures %d bytes then 0" % plain_before)
	if plain_before <= 0 or plain.get_cache_size_bytes() != 0:
		_fail += 1; print("    !! control dead: the measurement itself is not working")


# --- G. A frozen Graph modifier's cache knows WHERE it was solved (P4 §4.2) --------------------------
#
# `_extent_key` is "ox,oz,gw,gh" and the fallback parsed only fields 2 and 3, so a cached grid of the
# right SIZE was served for any PLACE: two same-sized loops under one Mound, and loop B got loop A's
# terrain. Silently — for a pure generator graph the staleness key is `g.content_key()`, which does not
# change when a loop moves.
func _g_a_frozen_graph_modifier_knows_where_it_is() -> void:
	print("[G] a frozen Graph modifier does not serve another loop's grid (§4.2)")
	var m := Pasture3DNodeGraph.new()
	m.evaluation = Pasture3DNode.Evaluation.FROZEN
	var grid := PackedFloat32Array(); grid.resize(8 * 8)
	for i in range(grid.size()):
		grid[i] = float(i)
	m.store_cache("0,0,8,8", {"key": 99, "grid": grid})

	# CONTROL FIRST: the exact key still hits. A `cache_for` that returned {} unconditionally would pass
	# every assertion below while disabling the cache entirely.
	var exact := m.cache_for("0,0,8,8")
	var exact_n: int = (exact.get("grid", PackedFloat32Array()) as PackedFloat32Array).size()
	print("    control: the exact extent hits (%d cells)" % exact_n)
	if exact_n != 64:
		_fail += 1; print("    !! control dead: the exact-key hit is gone, so this section proves nothing")

	var far := m.cache_for("640,640,8,8")
	print("    a loop 640 cells away: %s (want a miss)" % ("HIT" if not far.is_empty() else "miss"))
	if not far.is_empty():
		_fail += 1; print("    !! another loop's grid was served for a different origin")
	# And the miss is not memoised under the asking key, which is how the old fallback made the mistake
	# permanent: it wrote the borrowed entry back, so the next question got the same wrong answer faster.
	if m.cache_for("640,640,8,8").size() != far.size():
		_fail += 1; print("    !! the miss was written back into the cache")

	# The drag-jitter case the fallback was written for survives, as a TRANSLATION rather than a stretch:
	# one cell east reads one cell east, and the column that falls off the edge clamps.
	var near := m.cache_for("1,0,8,8")
	var ng: PackedFloat32Array = near.get("grid", PackedFloat32Array())
	print("    a loop 1 cell away: %s" % ("shifted" if ng.size() == 64 else "miss"))
	if ng.size() != 64:
		_fail += 1; print("    !! the one-cell drag tolerance was lost along with the fallback")
	elif ng[0] != grid[1] or ng[7] != grid[7]:
		_fail += 1; print("    !! the re-projection is not a whole-cell shift (got %.1f, %.1f; want %.1f, %.1f)"
				% [ng[0], ng[7], grid[1], grid[7]])
	# A dimension change is a miss, not a stretch.
	if not m.cache_for("0,0,16,4").is_empty():
		_fail += 1; print("    !! a 16x4 request was served from an 8x8 solve")


# --- H. A solver cache key carries its grid dimensions (P4 §4.4) -------------------------------------
#
# Lake Flooding and Stream Extraction keyed on `hash(arr.size()) ^ hash(arr)`. 512x128 and 128x512 hold
# the same cells in the same order, so a frozen Lake Flooding could not tell the two apart and served a
# lake surface solved for a grid of the other shape.
func _h_a_solver_key_carries_its_dimensions() -> void:
	print("[H] a solver's cache key distinguishes 512x128 from 128x512 (§4.4)")
	var arr := PackedFloat32Array(); arr.resize(512 * 128)
	for i in range(arr.size()):
		arr[i] = float(i % 97)
	var wide := Pasture3DGraphNode.solver_cache_key(512, 128, [arr])
	var tall := Pasture3DGraphNode.solver_cache_key(128, 512, [arr])
	print("    512x128 -> %d, 128x512 -> %d (want different)" % [wide, tall])
	if wide == tall:
		_fail += 1; print("    !! the same key for two shapes: a frozen solve crosses between them")
	# CONTROL: the key is still a function of the DATA, not a bare dimension pair — otherwise every solve
	# at one size would collide and the assertion above would pass on a key that cached nothing usefully.
	var moved := arr.duplicate()
	moved[0] += 1.0
	if Pasture3DGraphNode.solver_cache_key(512, 128, [moved]) == wide:
		_fail += 1; print("    !! control dead: the key ignores the grid contents")
	# And the same shape with the same data is the same key, or nothing would ever hit.
	if Pasture3DGraphNode.solver_cache_key(512, 128, [arr]) != wide:
		_fail += 1; print("    !! the key is not stable for identical inputs")


# --- I. The native path's stored key encodes the graph that produced the grid (P4 §4.4) --------------
#
# The native branch passed `{}` for both `inputs_of` and `input_ports_of`, so the per-port loop inside
# `_compute_node_inputs_hash` never ran and the output node's key came out of `[gw, gh, rect, muted, op]`
# alone — identical for every graph of the same size. The GDScript path at line 695 has always passed the
# real maps; this is the same call made the same way.
#
# What this does NOT test is the aux half, and deliberately: the native branch now declines to store a
# multi-output node at all rather than stamping `{}` over its channels, so the state that used to hand
# downstream `_read_channel` zeros is no longer reachable to assert on. Nor does it test parameter
# sensitivity — a node's signature carries no parameters at all, which is §4.3's finding and is covered
# by GraphNodeParamGate, not by this key.
func _i_the_native_path_keys_on_the_graph() -> void:
	print("[I] the native path stores a key that knows the graph shape (§4.4)")
	var g := Pasture3DTerrainGraph.new()
	var n := Pasture3DGraphNodeNoise.new()
	var fnl := FastNoiseLite.new(); fnl.seed = 3; fnl.frequency = 0.03
	n.noise = fnl; n.amplitude = 20.0
	var sm := Pasture3DGraphNodeSmooth.new(); sm.passes = 4
	var o := Pasture3DGraphNodeOutput.new()
	var nodes: Array[Pasture3DGraphNode] = [n, sm, o]
	g.nodes = nodes
	g.output_node = 2

	# CONTROL FIRST: the fixture has to reach the native branch, or the key under test is the GDScript
	# one and the section says nothing about the line it was written for.
	g.connections = [PackedInt32Array([0, 0, 2, 0])] # Noise -> Output
	print("    control: native_supported = %s (want true)" % g.native_supported())
	if not g.native_supported():
		_fail += 1; print("    !! the fixture does not lower to native, so [I] proves nothing")
		return
	g.evaluate(GW, GH, RECT)
	var direct: int = g.nodes[2]._inputs_hash

	g.connections = [PackedInt32Array([0, 0, 1, 0]), PackedInt32Array([1, 0, 2, 0])] # via Smooth
	g.emit_signal("structure_changed")
	g.evaluate(GW, GH, RECT)
	var via_smooth: int = g.nodes[2]._inputs_hash

	print("    Noise->Output key %d, Noise->Smooth->Output key %d (want different)" % [direct, via_smooth])
	if direct == via_smooth:
		_fail += 1; print("    !! the stored key is blind to the graph that produced the grid")


# ---- helpers -----------------------------------------------------------------------------------------

## Builds a 4-node pipeline: Noise(0) -> Smooth(1) -> Terrace(2) -> Output(3).
func _create_test_pipeline(p_amp: float, p_passes: int, p_band: float, p_hardness: float) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.new()
	
	var fnl := FastNoiseLite.new()
	fnl.seed = 1234
	fnl.frequency = 0.04
	
	var n_noise := Pasture3DGraphNodeNoise.new()
	n_noise.noise = fnl
	n_noise.amplitude = p_amp
	
	var n_smooth := Pasture3DGraphNodeSmooth.new()
	n_smooth.passes = p_passes
	
	var n_terrace := Pasture3DGraphNodeTerrace.new()
	n_terrace.band_height = p_band
	n_terrace.hardness = p_hardness
	
	# Per-node caching lives ONLY on the GDScript evaluator: `evaluate` tries the native whole-graph path
	# first, and that path is a single C++ call with no per-node buffers to cache — it stores exactly one
	# grid, the output's. Every op in a Noise -> Smooth -> Terrace chain is in the native allow-list, so
	# this fixture used to be evaluated natively and the gate measured nothing: sections B and C compared
	# two EMPTY cached buffers and read `empty == empty` as "upstream cache reused", and E's control
	# correctly reported itself dead because one cached grid can never exceed a 20 KB budget.
	#
	# The fixture is held on the GDScript path by `force_gdscript_evaluation`, an explicit switch on the
	# graph. It used to be held there by a Talus barrier whose `amount` was wired to port 4, because a wire
	# past in0..in3 was a native decline — and then driven scalars beyond port 3 became representable and
	# the barrier stopped barring. Borrowing a limitation as a premise means the premise expires without
	# notice. This says what it means, and costs the FIELD nothing, which a barrier node could not promise.
	var n_out := Pasture3DGraphNodeOutput.new()

	var nodes: Array[Pasture3DGraphNode] = [n_noise, n_smooth, n_terrace, n_out]
	g.nodes = nodes
	g.connections = [
		PackedInt32Array([0, 0, 1, 0]), # Noise -> Smooth
		PackedInt32Array([1, 0, 2, 0]), # Smooth -> Terrace
		PackedInt32Array([2, 0, 3, 0]), # Terrace -> Output
	]
	g.force_gdscript_evaluation = true
	g.output_node = IDX_OUTPUT
	return g


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var m := 0.0
	for i in range(p_a.size()):
		m = maxf(m, absf(p_a[i] - p_b[i]))
	return m


## The premise every other section rests on: this gate's fixture must NOT be evaluated natively, because
## the native path has no per-node cache to test. Asserted rather than assumed — the whole gate went
## quietly vacuous the day these ops joined the native allow-list, and nothing said so.
func _assert_gdscript_path() -> void:
	print("[premise] the fixture stays on the GDScript evaluator, which is the one with a per-node cache")
	var g := _create_test_pipeline(10.0, 2, 2.0, 0.8)
	print("    native_supported = %s (want false)" % g.native_supported())
	if g.native_supported():
		_fail += 1; print("    !! the fixture lowers to native, so every cache claim below is vacuous")
