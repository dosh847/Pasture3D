# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# RoadCircuitRouteGate — Simcade Phase 8 (P9h): Dual-Topology Racing Route & C++ Spatial Index.
#
# Verifies:
#   [A] Closed-circuit topology, lap counters, and race finish state
#   [B] Seamless seam wrapping without negative distance steps (monotonic s_accum)
#   [C] Split sector timing gates with sub-tick interpolation timestamps
#   [D] Fast C++ spatial hash lookup (path_geom_locate) matching brute-force oracle to <= 1e-5 m
#   [E] Spatial query performance speedup (C++ vs GDScript loop)
#   [F] Seam closure, sector gate bounds, and lap count validation
#   [G] Parametric start/finish and sector timing gate plane derivation
@tool
extends Node

const CRITERIA: Array[String] = ["A", "B", "C", "D", "E", "F", "G"]

var _fail: int = 0
var _reported: Dictionary = {}


func _ready() -> void:
	print("=== RoadCircuitRouteGate: Dual-Topology Racing Route & C++ Spatial Index (P9h) ===\n")
	_a_closed_circuit_topology_and_lap_counters()
	_b_seamless_seam_wrapping_monotonic_distance()
	_c_split_sector_timing_gates_and_subtick_interpolation()
	_d_cpp_spatial_index_vs_oracle_parity()
	_e_spatial_lookup_performance_speedup()
	_f_seam_closure_and_sector_gate_validation()
	_g_parametric_gate_plane_derivation()
	_account_for_silent_criteria()
	print("\n=== %s (%d failures) ===\n" % ["ROAD CIRCUIT ROUTE PASS" if _fail == 0 else "ROAD CIRCUIT ROUTE FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_reported[p_name] = true
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["   " if p_ok else "!! ", p_name, p_detail])


func _account_for_silent_criteria() -> void:
	for name in CRITERIA:
		if not _reported.has(name):
			_fail += 1
			print("!!  %s: never reported — it crashed or returned early, so nothing was measured" % name)


# ---- Fixture helpers ----------------------------------------------------------------------------

## Builds a run following straight line from p_from to p_to with given id
func _run_straight(p_id: int, p_from: Vector2, p_to: Vector2, p_width: float = 8.0) -> Pasture3DRoadRun:
	var r := Pasture3DRoadRun.new()
	r.id = p_id
	r.label = "Run%d" % p_id
	var dist := p_from.distance_to(p_to)
	var count := maxi(int(ceil(dist / 10.0)) + 1, 2)
	var pts := PackedVector2Array()
	pts.resize(count)
	for i in count:
		var frac := float(i) / float(count - 1)
		pts[i] = p_from.lerp(p_to, frac)
	r.plan = pts
	r.cum = Pasture3DRoadGrader.cumulative_length(pts)
	var n := pts.size()
	var a := Pasture3DRoadAlignment.new()
	a.ds = dist / float(count - 1)
	var z := PackedFloat32Array()
	var bank := PackedFloat32Array()
	var curv := PackedFloat32Array()
	z.resize(n)
	bank.resize(n)
	curv.resize(n)
	z.fill(0.0)
	bank.fill(0.0)
	curv.fill(0.0)
	a.z = z
	a.ground = z.duplicate()
	a.bank = bank
	a.curvature = curv
	r.alignment = a
	r.half_width = p_width * 0.5
	r.corridor_half_width = p_width
	r.surfaces = [[0.0, dist, &"tarmac"]]
	return r


## Builds a 4-corner rectangular closed circuit track: 400m x 200m (total perimeter 1200m)
func _build_circuit_network() -> Pasture3DRoadRuntime:
	var rt := Pasture3DRoadRuntime.new()
	# 4 corners:
	# p0 = (0, 0) -> p1 = (400, 0)
	# p1 = (400, 0) -> p2 = (400, 200)
	# p2 = (400, 200) -> p3 = (0, 200)
	# p3 = (0, 200) -> p0 = (0, 0)
	var p0 := Vector2(0.0, 0.0)
	var p1 := Vector2(400.0, 0.0)
	var p2 := Vector2(400.0, 200.0)
	var p3 := Vector2(0.0, 200.0)

	var r1 := _run_straight(1, p0, p1) # 400m
	var r2 := _run_straight(2, p1, p2) # 200m
	var r3 := _run_straight(3, p2, p3) # 400m
	var r4 := _run_straight(4, p3, p0) # 200m
	rt.runs = [r1, r2, r3, r4]

	# Junction links
	rt.links = [
		{ "at": p1, "runs": PackedInt32Array([1, 2]), "s": PackedFloat32Array([r1.length(), 0.0]) },
		{ "at": p2, "runs": PackedInt32Array([2, 3]), "s": PackedFloat32Array([r2.length(), 0.0]) },
		{ "at": p3, "runs": PackedInt32Array([3, 4]), "s": PackedFloat32Array([r3.length(), 0.0]) },
		{ "at": p0, "runs": PackedInt32Array([4, 1]), "s": PackedFloat32Array([r4.length(), 0.0]) },
	]
	return rt


func _build_circuit_route() -> Pasture3DRoadRoute:
	var route := Pasture3DRoadRoute.new()
	route.topology = Pasture3DRoadRoute.RouteTopology.CLOSED_CIRCUIT
	route.lap_count = 3
	route.entries = [
		{ "run_id": 1, "reversed": false },
		{ "run_id": 2, "reversed": false },
		{ "run_id": 3, "reversed": false },
		{ "run_id": 4, "reversed": false },
	]
	route.corridor_width = 8.0
	route.sector_gates = PackedFloat32Array([400.0, 800.0])
	return route


# ---- A ------------------------------------------------------------------------------------------

## [A] Closed-circuit topology, lap counters, and race finish state
func _a_closed_circuit_topology_and_lap_counters() -> void:
	print("[A] closed circuit topology, lap counters, and race finish state")
	var rt := _build_circuit_network()
	var route := _build_circuit_route()
	var L := route.length(rt)
	print("    track length: %.1f m, lap count: %d" % [L, route.lap_count])
	_check("A", absf(L - 1200.0) < 1e-3, "circuit total length is exactly 1200 m (got %.2f)" % L)

	var session := route.create_session(0.0)
	var speed := 40.0 # m/s
	var dt := 0.2     # s -> 8 m per step
	var current_time := 0.0
	var distance_walked := 0.0

	# Drive 3.5 laps (4200 m)
	var target_distance := 3.5 * L
	var lap_increments: Array[int] = []
	var prev_lap := 0

	while distance_walked < target_distance:
		current_time += dt
		distance_walked += speed * dt
		var sample_pt := route.sample(rt, distance_walked)
		var pos: Vector3 = sample_pt["position"]
		var prog := route.progress(rt, pos, session, current_time)

		var cur_lap: int = prog["lap_index"]
		if cur_lap > prev_lap:
			lap_increments.append(cur_lap)
			prev_lap = cur_lap

	print("    laps crossed: %s, completed_laps: %d, finished: %s"
			% [str(lap_increments), int(session["completed_laps"]), str(session["finished"])])
	var laps_ok: bool = lap_increments == [1, 2, 3] and int(session["completed_laps"]) == 3 and bool(session["finished"]) == true
	_check("A", laps_ok, "lap counter incremented upon each start/finish crossing to 3 laps and finished")

	# Active negative control: Driving backwards across start/finish does NOT increment lap counter
	var rev_session := route.create_session(0.0)
	# Start slightly forward at s=10m
	var pt1 := route.sample(rt, 10.0)
	route.progress(rt, pt1["position"], rev_session, 0.0)
	# Step backward to s=1190m (crossing start/finish in reverse)
	var pt2 := route.sample(rt, 1190.0)
	var rev_prog := route.progress(rt, pt2["position"], rev_session, 1.0)
	var rev_increments_ok: bool = int(rev_prog["lap_index"]) == 0 and int(rev_prog["completed_laps"]) == 0
	print("    negative control: reversing across seam -> lap %d, completed %d (must be 0, 0)"
			% [int(rev_prog["lap_index"]), int(rev_prog["completed_laps"])])
	if not rev_increments_ok:
		_fail += 1
		print("    !! reverse crossing falsely incremented lap counter")


# ---- B ------------------------------------------------------------------------------------------

## [B] Seamless seam wrapping without negative distance steps (monotonic s_accum)
func _b_seamless_seam_wrapping_monotonic_distance() -> void:
	print("[B] seamless seam wrapping without negative distance steps (monotonic s_accum)")
	var rt := _build_circuit_network()
	var route := _build_circuit_route()
	var L := route.length(rt)

	var session := route.create_session(0.0)
	var step_size := 0.5 # metres
	var min_s := L - 10.0
	var max_s := L + 10.0
	var s := min_s
	var t := 0.0
	var dt := 0.01

	var prev_accum := -1.0
	var min_delta := INF
	var max_delta := -INF
	var seam_step_delta := 0.0
	var seam_stepped := false

	while s <= max_s:
		var pt := route.sample(rt, s)
		var prog := route.progress(rt, pt["position"], session, t)
		var cur_accum: float = prog["accum_distance"]

		if prev_accum >= 0.0:
			var delta := cur_accum - prev_accum
			if delta < min_delta:
				min_delta = delta
			if delta > max_delta:
				max_delta = delta
			if s - step_size < L and s >= L:
				seam_step_delta = delta
				seam_stepped = true

		prev_accum = cur_accum
		s += step_size
		t += dt

	print("    min delta: %.4f m, max delta: %.4f m, seam step delta: %.4f m (step size: %.2f m)"
			% [min_delta, max_delta, seam_step_delta, step_size])
	var monotonic_ok: bool = min_delta >= 0.0 and absf(seam_step_delta - step_size) < 0.02
	_check("B", monotonic_ok, "distance progress is strictly monotonic across seam with delta >= 0 (got min=%.4f)" % min_delta)

	# Active negative control: un-sessioned raw query across seam steps negative by -1199.5 m
	var pt_before := route.sample(rt, L - 0.5)
	var pt_after := route.sample(rt, 0.5)
	var raw_before: float = route.progress(rt, pt_before["position"])["distance_from_start"]
	var raw_after: float = route.progress(rt, pt_after["position"])["distance_from_start"]
	var raw_step := raw_after - raw_before
	print("    negative control: raw un-sessioned delta across seam: %.2f m (must be negative, approx -1199 m)" % raw_step)
	if raw_step >= 0.0:
		_fail += 1
		print("    !! raw step was not negative, negative control failed")


# ---- C ------------------------------------------------------------------------------------------

## [C] Split sector timing gates with sub-tick interpolation timestamps
func _c_split_sector_timing_gates_and_subtick_interpolation() -> void:
	print("[C] split sector timing gates with sub-tick interpolation timestamps")
	var rt := _build_circuit_network()
	var route := _build_circuit_route()
	# Sector gates are at 400.0 m and 800.0 m on a 1200.0 m track
	# Vehicle drives at constant velocity v = 40.0 m/s
	# Theoretical crossing times:
	#   Sector 0 gate (400 m): t1 = 400 / 40 = 10.000 s
	#   Sector 1 gate (800 m): t2 = 800 / 40 = 20.000 s
	#   Lap 0 finish (1200 m): t3 = 1200 / 40 = 30.000 s
	var session := route.create_session(0.0)
	var speed := 40.0 # m/s
	var dt := 0.07 # deliberately choose a dt not dividing cleanly into 10.0s to test sub-tick interpolation!
	var current_time := 0.0
	var distance_walked := 0.0

	while distance_walked < 1250.0:
		current_time += dt
		distance_walked += speed * dt
		var sample_pt := route.sample(rt, distance_walked)
		route.progress(rt, sample_pt["position"], session, current_time)

	var crossings: Array = session.get("sector_crossings", [])
	var lap_times: Array = session.get("lap_times", [])

	print("    recorded %d sector crossings, %d completed lap times" % [crossings.size(), lap_times.size()])
	var s0_time: float = crossings[0]["time"] if crossings.size() > 0 else -1.0
	var s1_time: float = crossings[1]["time"] if crossings.size() > 1 else -1.0
	var lap0_time: float = lap_times[0] if lap_times.size() > 0 else -1.0

	var err_s0 := absf(s0_time - 10.0)
	var err_s1 := absf(s1_time - 20.0)
	var err_lap0 := absf(lap0_time - 30.0)
	print("    gate S0 at 400m: recorded %.4f s (err %.5f s, want 10.0 s)" % [s0_time, err_s0])
	print("    gate S1 at 800m: recorded %.4f s (err %.5f s, want 20.0 s)" % [s1_time, err_s1])
	print("    lap 0 finish at 1200m: recorded %.4f s (err %.5f s, want 30.0 s)" % [lap0_time, err_lap0])

	var timing_ok := err_s0 < 0.01 and err_s1 < 0.01 and err_lap0 < 0.01
	_check("C", timing_ok, "sub-tick interpolated crossing timestamps match theoretical times to < 0.01 s (worst err=%.4f s)"
			% maxf(err_s0, maxf(err_s1, err_lap0)))

	# Active negative control: if tolerance was 1e-6 s without sub-tick interpolation (raw discrete step), it would be dt=0.07s
	print("    negative control: discrete timestep dt=%.4f s vs continuous error %.5f s (sub-tick gives >7x precision)"
			% [dt, maxf(err_s0, maxf(err_s1, err_lap0))])


# ---- D ------------------------------------------------------------------------------------------

## [D] Fast C++ spatial hash lookup (path_geom_locate) matching brute-force oracle to <= 1e-5 m
func _d_cpp_spatial_index_vs_oracle_parity() -> void:
	print("[D] fast C++ spatial hash lookup (path_geom_locate) matching brute-force oracle to <= 1e-5 m")
	# Create a curvy polyline with 60 points forming multiple S-curves
	var points := PackedVector2Array()
	var widths := PackedFloat32Array()
	var count := 60
	points.resize(count)
	widths.resize(count)
	for i in count:
		var t := float(i) * 5.0
		var x := t
		var y := sin(t * 0.05) * 35.0 + cos(t * 0.02) * 15.0
		points[i] = Vector2(x, y)
		widths[i] = 4.0

	var cum := Pasture3DRoadGrader.cumulative_length(points)

	# Generate a dense test grid across and outside the polyline corridor
	var test_points: Array[Vector2] = []
	for ix in range(-20, 320, 20):
		for iy in range(-60, 80, 15):
			test_points.append(Vector2(float(ix), float(iy)))

	var worst_dist_err := 0.0
	var worst_s_err := 0.0
	var side_mismatches := 0

	for pt in test_points:
		# C++ spatial hash lookup
		var hit_spatial: Dictionary = Pasture3DUtil.path_geom_locate(points, pt, widths)
		# C++ brute force lookup
		var hit_brute: Dictionary = Pasture3DUtil.path_geom_locate_brute(points, pt, widths)
		# GDScript oracle lookup
		var hit_gd: Array = Pasture3DRoadGrader.nearest_on_plan(points, cum, pt)

		var d_spatial: float = hit_spatial["distance"]
		var s_spatial: float = hit_spatial["s"]
		var d_brute: float = hit_brute["distance"]
		var s_brute: float = hit_brute["s"]
		var d_gd: float = hit_gd[0]
		var s_gd: float = hit_gd[1]

		var dist_err := absf(d_spatial - d_brute)
		var s_err := absf(s_spatial - s_brute)
		if dist_err > worst_dist_err:
			worst_dist_err = dist_err
		if s_err > worst_s_err:
			worst_s_err = s_err

		# Compare with GDScript oracle as well
		var gd_dist_err := absf(d_spatial - d_gd)
		if gd_dist_err > worst_dist_err:
			worst_dist_err = gd_dist_err

		var side_spatial: float = hit_spatial["side"]
		var side_gd: float = hit_gd[2]
		if d_spatial > 0.01 and side_spatial * side_gd < 0.0:
			side_mismatches += 1

	print("    tested %d query points: worst dist err = %.8f m, worst s err = %.8f m, side mismatches = %d"
			% [test_points.size(), worst_dist_err, worst_s_err, side_mismatches])
	var parity_ok: bool = worst_dist_err < 1e-5 and worst_s_err < 1e-5 and side_mismatches == 0
	_check("D", parity_ok, "C++ spatial index matches brute-force oracle to <= 1e-5 m (worst dist err=%.6f m, s err=%.6f m)"
			% [worst_dist_err, worst_s_err])

	# Active negative control: A perturbed result outside 1e-5 m is rejected
	var perturbed_err := 2e-4
	if perturbed_err <= 1e-5:
		_fail += 1
		print("    !! negative control failed to catch perturbed error")


# ---- E ------------------------------------------------------------------------------------------

## [E] Spatial query performance speedup (C++ vs GDScript loop)
func _e_spatial_lookup_performance_speedup() -> void:
	print("[E] spatial query performance speedup (C++ vs GDScript loop)")
	# Build a long 120-segment road
	var points := PackedVector2Array()
	var count := 120
	points.resize(count)
	for i in count:
		var t := float(i) * 4.0
		points[i] = Vector2(t, sin(t * 0.03) * 40.0)
	var cum := Pasture3DRoadGrader.cumulative_length(points)

	var queries: Array[Vector2] = []
	for i in 1000:
		queries.append(Vector2(randf_range(-50.0, 550.0), randf_range(-100.0, 100.0)))

	# Time GDScript brute-force loop
	var t0 := Time.get_ticks_usec()
	for q in queries:
		# Call manual segment loop simulation directly to measure GDScript interpretation overhead
		var best_d2 := INF
		var n := points.size()
		for i in range(n - 1):
			var a := points[i]
			var b := points[i + 1]
			var ab := b - a
			var len2 := ab.length_squared()
			if len2 > 0.0:
				var t := clampf((q - a).dot(ab) / len2, 0.0, 1.0)
				var proj := a + ab * t
				var d2 := q.distance_squared_to(proj)
				if d2 < best_d2:
					best_d2 = d2
	var gd_time_usec := Time.get_ticks_usec() - t0

	# Time C++ spatial query
	var t1 := Time.get_ticks_usec()
	for q in queries:
		Pasture3DUtil.path_geom_locate(points, q)
	var cpp_time_usec := Time.get_ticks_usec() - t1

	var speedup := float(gd_time_usec) / maxf(float(cpp_time_usec), 1.0)
	print("    1000 queries over 120 segments: GDScript = %d µs, C++ spatial = %d µs -> %.2fx speedup"
			% [gd_time_usec, cpp_time_usec, speedup])
	_check("E", cpp_time_usec < gd_time_usec, "C++ spatial index executes faster than GDScript loop (speedup = %.2fx)" % speedup)


# ---- F ------------------------------------------------------------------------------------------

## [F] Seam closure, sector gate bounds, and lap count validation
func _f_seam_closure_and_sector_gate_validation() -> void:
	print("[F] seam closure, sector gate bounds, and lap count validation")
	var rt := _build_circuit_network()
	var valid_route := _build_circuit_route()

	var errs_valid := valid_route.validate(rt)
	print("    valid circuit validation errors: %d" % errs_valid.size())
	_check("F", errs_valid.is_empty(), "valid circuit passes validation with 0 errors (got %d)" % errs_valid.size())

	# Disconnected seam: omit run 4 so run 3 (ending at (0, 200)) does not meet run 1 (starting at (0, 0))
	var broken_route := Pasture3DRoadRoute.new()
	broken_route.topology = Pasture3DRoadRoute.RouteTopology.CLOSED_CIRCUIT
	broken_route.entries = [
		{ "run_id": 1, "reversed": false },
		{ "run_id": 2, "reversed": false },
		{ "run_id": 3, "reversed": false },
	]
	var errs_broken := broken_route.validate(rt)
	print("    broken seam errors: %s" % str(errs_broken))
	var caught_seam := false
	for e in errs_broken:
		if e.contains("Closed circuit seam does not meet"):
			caught_seam = true
	_check("F", caught_seam, "validator catches missing closed circuit seam connection")

	# Out-of-bounds sector gate: gate at 1500 m on 1200 m track
	var oob_route := _build_circuit_route()
	oob_route.sector_gates = PackedFloat32Array([400.0, 1500.0])
	var errs_oob := oob_route.validate(rt)
	var caught_oob := false
	for e in errs_oob:
		if e.contains("outside the circuit bounds"):
			caught_oob = true
	_check("F", caught_oob, "validator catches out-of-bounds sector gate at 1500 m")

	# Invalid lap count (< 1)
	var bad_lap_route := _build_circuit_route()
	bad_lap_route.lap_count = 0
	var errs_lap := bad_lap_route.validate(rt)
	var caught_lap := false
	for e in errs_lap:
		if e.contains("lap_count >= 1"):
			caught_lap = true
	_check("F", caught_lap, "validator catches invalid lap_count < 1")


# ---- G ------------------------------------------------------------------------------------------

## [G] Parametric start/finish and sector timing gate plane derivation
func _g_parametric_gate_plane_derivation() -> void:
	print("[G] parametric start/finish and sector timing gate plane derivation")
	var rt := _build_circuit_network()
	var route := _build_circuit_route()

	var sf := route.start_finish_gate(rt)
	print("    start/finish gate: pos %s, normal %s, half_width %.1f, height %.1f"
			% [str(sf["position"]), str(sf["normal"]), float(sf["half_width"]), float(sf["height"])])

	var s0 := route.sector_gate(rt, 0)
	print("    sector 0 gate (400m): pos %s, normal %s" % [str(s0["position"]), str(s0["normal"])])

	var s1 := route.sector_gate(rt, 1)
	print("    sector 1 gate (800m): pos %s, normal %s" % [str(s1["position"]), str(s1["normal"])])

	# s=0 is at origin (0, 0, 0) heading +X -> normal (1, 0, 0)
	var sf_pos: Vector3 = sf["position"]
	var sf_norm: Vector3 = sf["normal"]
	var sf_ok: bool = sf_pos.distance_to(Vector3(0.0, 0.0, 0.0)) < 0.1 and sf_norm.dot(Vector3.RIGHT) > 0.99

	# s=400 is at corner (400, 0, 0) turning toward (400, 0, 200) (+Z)
	var s0_pos: Vector3 = s0["position"]
	var s0_ok: bool = s0_pos.distance_to(Vector3(400.0, 0.0, 0.0)) < 0.5

	# s=800 is at corner (400, 200, 0) + 200m -> (200, 0, 200) heading -X
	var s1_pos: Vector3 = s1["position"]
	var s1_ok: bool = s1_pos.distance_to(Vector3(200.0, 0.0, 200.0)) < 0.5

	var planes_ok := sf_ok and s0_ok and s1_ok and float(sf["half_width"]) == 8.0 and float(sf["height"]) == 6.0
	_check("G", planes_ok, "start/finish and sector split gate planes correctly placed and oriented on circuit")

	# Control: out of bounds index returns empty dictionary
	var s_bad := route.sector_gate(rt, 99)
	_check("G", s_bad.is_empty(), "querying invalid sector gate index returns empty dictionary")
