# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# SolverThreadParityGate — the graph solvers bake the same field at 1 thread as at every thread, and the
# persistent pool they now share survives several callers at once.
#
# The claim under test: splitting erosion_solve's D8 receiver pass and hillslope diffusion, Salève's setup,
# receiver, post-smooth, tonal and composite passes, warp_downslope's cell loop, and the four SCATTER kernels
# (hydraulic, thermal, talus projection, mudslide) across rows changed NOTHING — bitwise, every output
# channel. And the pool those regions now run on (parked workers instead of a thread per region) does not
# deadlock or cross-talk when a WorkerThreadPool task and the main thread solve at the same time, which is
# exactly what the brush deferred driver and a graph preview do.
#
# Each solver arm:
#   A  the serial arm (`set_max_threads(1)`) splits no region and the threaded arm splits at least the
#      regions its passes imply — a per-ITERATION count, so it proves the solver loops split, not just one
#      pass somewhere. Without A, B could be comparing serial with serial.
#   F  THE FLOOR: two threaded solves are bitwise identical.
#   B  serial == threaded, bitwise, on every channel the binding returns.
#   C  each threaded pass reaches the output: switching it off moves the field. (A pass whose output never
#      reaches a channel is one B says nothing about.)
# And the pool:
#   P  four WorkerThreadPool tasks and the main thread run the same solve at once — erosion_solve, and
#      thermal erosion for the scatter kernels' per-chunk record windows. Every result equals the serial one
#      bitwise, and the pool counted exactly five solves' worth of splits — so no caller silently fell back
#      to serial.
#
# B cannot see a scatter kernel that is WRONG THE SAME WAY at every thread count: its serial and threaded arms
# run the same record-and-replay code. So the gate also takes a reference file, written by an earlier build:
#   R  (only with --check-reference) every arm's serial output equals the reference build's, bitwise.
#   --write-reference=PATH   store every arm's serial output (run this on the build BEFORE a kernel change)
#   --check-reference=PATH   compare against it (run this AFTER), and fail on any arm missing from either
#
# The main fixture is a 241 x 199 grid: past the pool's 128-row and 16384-element floors, and NOT square, so
# a row/column mix-up in a partition cannot hide. It carries a NaN hole, the no-data branch every solver has.
# The scatter kernels also run on a 3 x 300 strip, where most cells sit on a grid edge and every chunk is
# mostly its own halo rows.
#
# This is a correctness gate, not a benchmark: it prints split counts, never timings.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/SolverThreadParityGate.tscn
#      [-- --write-reference=PATH | -- --check-reference=PATH]
extends Node

const GW := 241
const GH := 199
const CELL := 2.0
const TASKS := 4
const STRIP_GW := 3
const STRIP_GH := 300

## Completions this gate must reach; a criterion that returned early completed nothing.
const EXPECTED := 24

const EROSION := {
	"iterations": 8, "time_step": 1.0, "erosion_rate": 0.002, "area_exponent": 0.45,
	"diffusion": 1.5, "fill_depressions": true, "fill_every": 1,
}
const SALEVE := {
	"iterations": 12, "seed": 5, "drainage_noise": 0.25, "bank_smoothing": 0.2, "control_points": 20000,
	"deposition_radius": 8.0, "deposition_strength": 0.4, "stream_strength": 0.05,
}
const HYDRAULIC := {"iterations": 12}
const THERMAL := {"talus_angle_deg": 32.0, "iterations": 10, "settling_rate": 0.65}
const TALUS := {"talus_angle_deg": 35.0, "iterations": 12, "transfer_rate": 0.5, "amount": 0.85}
const MUDSLIDE := {
	"talus_angle_deg": 30.0, "depth_m": 2.0, "travel_distance_m": 60.0, "depth_exponent": 1.0,
	"viscosity_power": 1.5, "amount": 1.0,
}

var _fail := 0
var _done := 0
var _surface := PackedFloat32Array()
var _rect := Rect2(0.0, 0.0, GW * CELL, GH * CELL)
var _main := {}
var _strip := {}

var _ref_write := ""
var _ref_check := ""
var _ref := {}
var _ref_matched := 0


func _ready() -> void:
	print("\n=== SolverThreadParityGate: 1 thread == every thread, and the pool under concurrent callers ===\n")
	var cap_before: int = Pasture3DUtil.get_max_threads()
	if OS.get_processor_count() < 2:
		_fail += 1
		print("    !! one hardware thread: nothing can split, so this machine cannot run the gate")
	elif _open_reference():
		_surface = _make_surface()
		_main = {"surface": _surface, "gw": GW, "gh": GH, "rect": _rect, "mask": _make_mask()}
		_strip = _make_strip()
		_run()
		_close_reference()
	Pasture3DUtil.set_max_threads(cap_before)

	if _done != EXPECTED:
		_fail += 1
		print("\n    !! only %d of %d criteria completed" % [_done, EXPECTED])
	print("\n=== %s (%d failures) ===\n" % ["SOLVER THREAD PARITY PASS" if _fail == 0 else "SOLVER THREAD PARITY FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _run() -> void:
	# ---- erosion_solve ----------------------------------------------------------------------------
	# Receivers once per iteration, then two diffusion regions per sub-step: at least 3 per iteration.
	var e1 := _check("E1 erosion_solve, detachment-limited + diffusion", _erosion.bind(EROSION),
			EROSION.iterations * 3)
	if not e1.is_empty():
		print("  [E1-C] each threaded pass reaches z:")
		var ok := true
		ok = _control("diffusion off", e1.z, _erosion(_with(EROSION, "diffusion", 0.0)).z) and ok
		ok = _control("incision off (the receiver pass's consumer)", e1.z,
				_erosion(_with(EROSION, "erosion_rate", 0.0)).z) and ok
		var peak := _peak(e1.flow)
		print("    %-52s max flow %.0f m² (want > %.0f)" % ["receivers route flow", peak, CELL * CELL * 100.0])
		if peak <= CELL * CELL * 100.0:
			_fail += 1
			ok = false
			print("    !! the drainage area never collects, so the receiver pass is not routing anything")
		if ok:
			_done += 1

	_check("E2 erosion_solve with deposition (the Gauss-Seidel sweep reads the threaded receivers)",
			_erosion.bind(_with(EROSION, "deposition", 0.5)), EROSION.iterations * 3)

	# ---- Salève -----------------------------------------------------------------------------------
	# Receivers (>= 1 iteration before convergence), reconstruction, post-smooth, composite. 20000 control
	# points, because the pool runs a vertex pass of under 16384 elements serial and the receivers would
	# never split.
	var s := _check("S hydraulic_saleve_solve", _saleve.bind(SALEVE), 4)
	if not s.is_empty():
		print("  [S-C] each threaded pass reaches height:")
		var ok := true
		ok = _control("bank smoothing off (post-smooth pass)", s.height,
				_saleve(_with(SALEVE, "bank_smoothing", 0.0)).height) and ok
		ok = _control("drainage noise off (receiver pass)", s.height,
				_saleve(_with(SALEVE, "drainage_noise", 0.0)).height) and ok
		ok = _control("erosion strength 0.25 (composite pass)", s.height,
				_saleve(_with(SALEVE, "erosion_strength", 0.25)).height) and ok
		if ok:
			_done += 1

	# ---- warp_downslope ---------------------------------------------------------------------------
	# Radius 0 takes no box-mean pre-blur, so every split counted here is the warp's own loop.
	var w := _check("W warp_downslope, raw gradient", _warp.bind(PackedFloat32Array(), 4.0, 0.0, false, 1.0), 1)
	if not w.is_empty():
		print("  [W-C] the threaded loop reaches height:")
		var ok := true
		ok = _control("warp vs the input it warped", w.height, _surface) and ok
		ok = _control("displacement 2 m instead of 4", w.height,
				_warp(PackedFloat32Array(), 2.0, 0.0, false, 1.0).height) and ok
		if ok:
			_done += 1
	_check("W2 warp_downslope, smoothed gradient + mask + reverse",
			_warp.bind(_make_mask(), 3.0, 6.0, true, 0.8), 1)

	# ---- the scatter kernels ----------------------------------------------------------------------
	# Each one pushes into its neighbours, so a threaded sweep records every source and replays the terms
	# each destination receives in the order the serial raster walk delivered them.
	var none := PackedFloat32Array()

	# Rain (elements) and the routing sweep (rows) each split once per iteration.
	var h := _check("H erosion_hydraulic_solve", _hydraulic.bind(_main, HYDRAULIC), HYDRAULIC.iterations * 2)
	if not h.is_empty():
		print("  [H-C] the routing sweep's scatter reaches the output:")
		var ok := true
		ok = _control("routing vs the input it eroded", h.height, _surface) and ok
		ok = _control("evaporation 1.0 (scattered water never reaches the next pass)", h.height,
				_hydraulic(_main, _with(HYDRAULIC, "evaporation_rate", 1.0)).height) and ok
		ok = _positive("material laid down by the scatter", h.deposited) and ok
		if ok:
			_done += 1

	var t := _check("T erosion_thermal_solve", _thermal.bind(_main, none, THERMAL), THERMAL.iterations)
	var t2 := _check("T2 erosion_thermal_solve with hardness", _thermal.bind(_main, _main.mask, THERMAL),
			THERMAL.iterations)
	if not t.is_empty() and not t2.is_empty():
		print("  [T-C] the slip scatter reaches the output:")
		var ok := true
		ok = _control("slip vs the input it slumped", t.height, _surface) and ok
		ok = _control("hardness field (raises the per-cell talus angle)", t.height, t2.height) and ok
		ok = _positive("talus accumulated from neighbours", t.talus) and ok
		if ok:
			_done += 1

	var tp := _check("TP talus_projection_solve", _talus.bind(_main, _main.mask, TALUS), TALUS.iterations)
	if not tp.is_empty():
		print("  [TP-C] the transfer scatter reaches the output:")
		var ok := true
		ok = _control("projection vs its input", tp.height, _surface) and ok
		ok = _control("transfer rate 0.25 instead of 0.5", tp.height,
				_talus(_main, _main.mask, _with(TALUS, "transfer_rate", 0.25)).height) and ok
		if ok:
			_done += 1

	# One sweep per cell of travel (60 m / 2 m), plus the mobile-pool setup.
	var m := _check("M mudslide_solve, talus-gated pool", _mudslide.bind(_main, none, MUDSLIDE), 30)
	var m2 := _check("M2 mudslide_solve, masked pool", _mudslide.bind(_main, _main.mask, MUDSLIDE), 30)
	if not m.is_empty() and not m2.is_empty():
		print("  [M-C] the slide scatter reaches the output:")
		var ok := true
		ok = _control("slide vs its input", m.height, _surface) and ok
		ok = _control("masked pool vs the talus gate", m.height, m2.height) and ok
		ok = _positive("deposition", m.deposition) and ok
		if ok:
			_done += 1

	# The strip: 3 columns, so most cells are on an edge and a missing bounds check reads the wrong row.
	var sw: int = _strip.gw
	_check("N-H hydraulic on the 3 x 300 strip", _hydraulic.bind(_strip, HYDRAULIC), HYDRAULIC.iterations, sw)
	_check("N-T thermal on the strip", _thermal.bind(_strip, none, THERMAL), THERMAL.iterations, sw)
	_check("N-TP talus projection on the strip", _talus.bind(_strip, none, TALUS), TALUS.iterations, sw)
	_check("N-M mudslide on the strip", _mudslide.bind(_strip, none, MUDSLIDE), 30, sw)

	# ---- the pool under concurrent callers --------------------------------------------------------
	if not e1.is_empty():
		_concurrent("P erosion_solve", _erosion.bind(EROSION), "z", int(e1._splits))
	if not t.is_empty():
		_concurrent("P2 erosion_thermal_solve", _thermal.bind(_main, none, THERMAL), "height", int(t._splits))


## A, F and B for one solver arm, and R when a reference is open. Returns the threaded result, or {} when the
## arm could not be measured.
func _check(p_label: String, p_solve: Callable, p_min_splits: int, p_gw: int = GW) -> Dictionary:
	print("\n[%s]" % p_label)
	Pasture3DUtil.set_max_threads(1)
	var d0: int = Pasture3DUtil.parallel_dispatch_count()
	var serial: Dictionary = p_solve.call()
	var d_serial: int = Pasture3DUtil.parallel_dispatch_count() - d0
	Pasture3DUtil.set_max_threads(0)
	d0 = Pasture3DUtil.parallel_dispatch_count()
	var threaded: Dictionary = p_solve.call()
	var d_threaded: int = Pasture3DUtil.parallel_dispatch_count() - d0
	var again: Dictionary = p_solve.call()

	if serial.is_empty() or threaded.is_empty() or again.is_empty():
		_fail += 1
		print("    !! the solver returned nothing")
		return {}
	_reference(p_label.get_slice(" ", 0), serial, p_gw)
	var ok := true
	print("    A  regions split: serial %d (want 0), threaded %d (want >= %d)" % [d_serial, d_threaded, p_min_splits])
	if d_serial != 0:
		_fail += 1
		ok = false
		print("    !! set_max_threads(1) still split a region — the serial arm is not serial")
	if d_threaded < p_min_splits:
		_fail += 1
		ok = false
		print("    !! the threaded arm split fewer regions than its passes imply — B may compare serial with serial")

	var floor_diff := _difference(threaded, again, p_gw)
	print("    F  threaded twice: %s" % ("bitwise identical" if floor_diff.is_empty() else floor_diff))
	if not floor_diff.is_empty():
		_fail += 1
		print("    !! a solve does not repeat itself; no bitwise comparison below means anything")
		return {}

	var diff := _difference(serial, threaded, p_gw)
	print("    B  serial vs threaded over %s: %s"
			% [", ".join(PackedStringArray(serial.keys())), "bitwise identical" if diff.is_empty() else diff])
	if not diff.is_empty():
		_fail += 1
		ok = false
		print("    !! threading changed the solve")
	if ok:
		_done += 1
	threaded["_splits"] = d_threaded
	return threaded


func _concurrent(p_label: String, p_solve: Callable, p_channel: String, p_splits: int) -> void:
	print("\n[%s] %d WorkerThreadPool tasks and the main thread solve at once:" % [p_label, TASKS])
	Pasture3DUtil.set_max_threads(1)
	var serial: PackedFloat32Array = p_solve.call()[p_channel]
	Pasture3DUtil.set_max_threads(0)

	# One Dictionary per caller, touched by nothing else until its task is joined.
	var slots: Array[Dictionary] = []
	for i in range(TASKS + 1):
		slots.append({})
	var d0: int = Pasture3DUtil.parallel_dispatch_count()
	var ids: Array[int] = []
	for i in range(TASKS):
		ids.append(WorkerThreadPool.add_task(_solve_into.bind(slots[i], p_solve, p_channel), true, "SolverThreadParityGate"))
	_solve_into(slots[TASKS], p_solve, p_channel)
	for id in ids:
		WorkerThreadPool.wait_for_task_completion(id)
	var splits: int = Pasture3DUtil.parallel_dispatch_count() - d0
	var want: int = (TASKS + 1) * p_splits

	var ok := true
	print("    regions split: %d (want exactly %d: %d solves x %d)" % [splits, want, TASKS + 1, p_splits])
	if splits != want:
		_fail += 1
		ok = false
		print("    !! a concurrent caller did not split the way a lone one does")
	for i in range(TASKS + 1):
		var out: PackedFloat32Array = slots[i].get(p_channel, PackedFloat32Array())
		var same := not out.is_empty() and out.to_byte_array() == serial.to_byte_array()
		print("    caller %d (%s): %s" % [i, "main thread" if i == TASKS else "task", "== serial" if same else "DIFFERS"])
		if not same:
			_fail += 1
			ok = false
	if ok:
		_done += 1


func _solve_into(p_slot: Dictionary, p_solve: Callable, p_channel: String) -> void:
	p_slot[p_channel] = p_solve.call().get(p_channel, PackedFloat32Array())


# ---- solvers -----------------------------------------------------------------------------------------


func _erosion(p_params: Dictionary) -> Dictionary:
	var r: Dictionary = Pasture3DUtil.erosion_solve_grid(_surface, GW, GH, CELL, p_params, PackedFloat32Array())
	if not r.get("ok", false):
		return {}
	return {"z": r.z, "flow": r.flow, "ero": r.ero, "dep": r.dep, "wet": r.wet}


func _saleve(p_params: Dictionary) -> Dictionary:
	var r: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(_surface, GW, GH, _rect, p_params)
	if not r.get("ok", false):
		return {}
	return {"height": r.height, "eroded_rock": r.eroded_rock, "sediment": r.sediment}


func _warp(p_mask: PackedFloat32Array, p_displacement: float, p_radius: float, p_reverse: bool,
		p_amount: float) -> Dictionary:
	var r: PackedFloat32Array = Pasture3DUtil.warp_downslope_grid(_surface, p_mask, GW, GH, _rect,
			p_displacement, p_radius, p_reverse, p_amount)
	if r.size() != GW * GH:
		return {}
	return {"height": r}


func _hydraulic(p_fixture: Dictionary, p_params: Dictionary) -> Dictionary:
	var r: Dictionary = Pasture3DUtil.erosion_hydraulic_solve_grid(p_fixture.surface, p_fixture.gw,
			p_fixture.gh, p_fixture.rect, p_params)
	if not r.get("ok", false):
		return {}
	return {"height": r.height, "eroded": r.eroded, "deposited": r.deposited, "flow": r.flow}


func _thermal(p_fixture: Dictionary, p_hardness: PackedFloat32Array, p_params: Dictionary) -> Dictionary:
	var r: Dictionary = Pasture3DUtil.erosion_thermal_solve_grid(p_fixture.surface, p_hardness, p_fixture.gw,
			p_fixture.gh, p_fixture.rect, p_params.talus_angle_deg, p_params.iterations, p_params.settling_rate)
	if not r.get("ok", false):
		return {}
	return {"height": r.height, "talus": r.talus}


func _talus(p_fixture: Dictionary, p_mask: PackedFloat32Array, p_params: Dictionary) -> Dictionary:
	var r: PackedFloat32Array = Pasture3DUtil.talus_projection_grid(p_fixture.surface, p_mask, p_fixture.gw,
			p_fixture.gh, p_fixture.rect, p_params.talus_angle_deg, p_params.iterations, p_params.transfer_rate,
			p_params.amount)
	if r.size() != p_fixture.gw * p_fixture.gh:
		return {}
	return {"height": r}


func _mudslide(p_fixture: Dictionary, p_mask: PackedFloat32Array, p_params: Dictionary) -> Dictionary:
	var r: Dictionary = Pasture3DUtil.mudslide_grid(p_fixture.surface, p_mask, p_fixture.gw, p_fixture.gh,
			p_fixture.rect, p_params.talus_angle_deg, p_params.depth_m, p_params.travel_distance_m,
			p_params.depth_exponent, p_params.viscosity_power, p_params.amount)
	var height: PackedFloat32Array = r.get("height", PackedFloat32Array())
	if height.size() != p_fixture.gw * p_fixture.gh:
		return {}
	return {"height": height, "deposition": r.deposition}


# ---- fixture -----------------------------------------------------------------------------------------


func _make_surface() -> PackedFloat32Array:
	var noise := FastNoiseLite.new()
	noise.seed = 97
	noise.frequency = 0.012
	noise.fractal_octaves = 5
	var out := PackedFloat32Array()
	out.resize(GW * GH)
	for z in range(GH):
		for x in range(GW):
			# A gentle tilt so the drainage network has somewhere to go besides every edge at once.
			var h := 40.0 + 60.0 * noise.get_noise_2d(x * CELL, z * CELL) + 0.08 * x * CELL
			# The no-data hole: every solver has a NaN branch, and it has to run on both arms.
			if Vector2(x - 180, z - 60).length() < 14.0:
				h = NAN
			out[z * GW + x] = h
	return out


## A radial 0..1 ramp, so the masked warp weights cells differently across every row split.
func _make_mask() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(GW * GH)
	var centre := Vector2(GW * 0.4, GH * 0.55)
	var reach := float(maxi(GW, GH)) * 0.6
	for z in range(GH):
		for x in range(GW):
			out[z * GW + x] = clampf(1.0 - Vector2(x, z).distance_to(centre) / reach, 0.0, 1.0)
	return out


## A steep rough ramp down a 3-wide strip — steeper than every talus angle above, so every kernel moves
## material on every row — with one NaN cell in its middle column.
func _make_strip() -> Dictionary:
	var noise := FastNoiseLite.new()
	noise.seed = 31
	noise.frequency = 0.05
	var surface := PackedFloat32Array()
	surface.resize(STRIP_GW * STRIP_GH)
	for z in range(STRIP_GH):
		for x in range(STRIP_GW):
			surface[z * STRIP_GW + x] = 1.2 * (STRIP_GH - z) * CELL + 20.0 * noise.get_noise_2d(x * CELL, z * CELL)
	surface[150 * STRIP_GW + 1] = NAN
	return {"surface": surface, "gw": STRIP_GW, "gh": STRIP_GH, "rect": Rect2(0.0, 0.0, STRIP_GW * CELL, STRIP_GH * CELL)}


# ---- the reference build -----------------------------------------------------------------------------


func _open_reference() -> bool:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--write-reference="):
			_ref_write = arg.get_slice("=", 1)
		elif arg.begins_with("--check-reference="):
			_ref_check = arg.get_slice("=", 1)
	if _ref_check.is_empty():
		return true
	var file := FileAccess.open(_ref_check, FileAccess.READ)
	if file == null:
		_fail += 1
		print("    !! cannot open the reference %s" % _ref_check)
		return false
	_ref = file.get_var()
	print("R: comparing against the reference build in %s (%d arms)" % [_ref_check, _ref.size()])
	return true


func _reference(p_id: String, p_serial: Dictionary, p_gw: int) -> void:
	if not _ref_write.is_empty():
		var channels := {}
		for key in p_serial.keys():
			if p_serial[key] is PackedFloat32Array:
				channels[key] = p_serial[key]
		_ref[p_id] = channels
		return
	if _ref_check.is_empty():
		return
	if not _ref.has(p_id):
		_fail += 1
		print("    !! R  %s is not in the reference file" % p_id)
		return
	var diff := _difference(_ref[p_id], p_serial, p_gw)
	print("    R  serial vs the reference build: %s" % ("bitwise identical" if diff.is_empty() else diff))
	if diff.is_empty():
		_ref_matched += 1
	else:
		_fail += 1
		print("    !! the solve no longer matches the build the reference was written by")


func _close_reference() -> void:
	if not _ref_write.is_empty():
		var file := FileAccess.open(_ref_write, FileAccess.WRITE)
		if file == null:
			_fail += 1
			print("\n    !! cannot write the reference %s" % _ref_write)
			return
		file.store_var(_ref)
		print("\nR: wrote %d arms to %s" % [_ref.size(), _ref_write])
	elif not _ref_check.is_empty():
		print("\nR: %d of %d reference arms bitwise identical" % [_ref_matched, _ref.size()])
		if _ref_matched != _ref.size():
			_fail += 1
			print("    !! an arm in the reference was never matched")


# ---- measurement -------------------------------------------------------------------------------------


func _with(p_params: Dictionary, p_key: String, p_value) -> Dictionary:
	var d := p_params.duplicate()
	d[p_key] = p_value
	return d


## "" when every channel is byte-identical, else where the first one differs. Bytes, not values: a NaN
## payload that changed is a difference too, and `==` on a NaN cannot see it.
func _difference(p_a: Dictionary, p_b: Dictionary, p_gw: int = GW) -> String:
	for key in p_a.keys():
		if not (p_a[key] is PackedFloat32Array):
			continue
		var a: PackedFloat32Array = p_a[key]
		var b: PackedFloat32Array = p_b.get(key, PackedFloat32Array())
		if a.to_byte_array() == b.to_byte_array():
			continue
		if a.size() != b.size():
			return "%s: sizes %d vs %d" % [key, a.size(), b.size()]
		for i in range(a.size()):
			if a[i] != b[i] and not (is_nan(a[i]) and is_nan(b[i])):
				return "%s differs first at cell (%d, %d), max |d| %.9f" % [key, i % p_gw, i / p_gw, _max_abs_diff(a, b)]
		return "%s differs only in NaN payloads or zero signs" % key
	return ""


func _control(p_label: String, p_full: PackedFloat32Array, p_other: PackedFloat32Array) -> bool:
	var moved := p_full.to_byte_array() != p_other.to_byte_array()
	print("    %-52s %s" % [p_label, "moves %.4f m" % _max_abs_diff(p_full, p_other) if moved else "INERT"])
	if not moved:
		_fail += 1
		print("    !! switching it off changed nothing, so B says nothing about its threaded split")
	return moved


## A channel that only neighbours write into must hold something, or the scatter B compared was empty.
func _positive(p_label: String, p_vals: PackedFloat32Array) -> bool:
	var peak := _peak(p_vals)
	print("    %-52s peak %.4f (want > 0)" % [p_label, peak])
	if peak <= 0.0:
		_fail += 1
		print("    !! nothing was scattered into this channel")
	return peak > 0.0


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	var worst := 0.0
	for i in range(mini(p_a.size(), p_b.size())):
		if is_finite(p_a[i]) and is_finite(p_b[i]):
			worst = maxf(worst, absf(p_a[i] - p_b[i]))
	return worst


func _peak(p_vals: PackedFloat32Array) -> float:
	var hi := 0.0
	for v in p_vals:
		if is_finite(v):
			hi = maxf(hi, v)
	return hi
