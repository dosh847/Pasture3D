# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSaleveStreamPowerGate — Salève Hydraulic Erosion (saleve_stream_power): uplift and stream-power incision
# integrated through time (PASTURE3D_SALEVE_STRATA_FIDELITY_SPEC.md, "Salève Hydraulic Erosion").
#
# SA a zero duration is the identity: height is the input bit for bit and eroded_rock is zero. Control: the
#    default duration moves the ground by metres and erodes rock.
# SB the steady state is the stream-power law: after a long run, every channel vertex stands at
#    S = u^(1/n) G (A_ch / A)^(m/n) toward its receiver (median error <= 2 %), at n = 1 and n = 1.5, under an
#    uplift field that ramps 0.25..1 across the area. Controls: a short run is not at steady state, and the
#    same slopes read against u = 1 (the uplift field ignored) miss the law.
# SC every vertex drains to an outlet by its receivers, on an island with a crater. Control: with lake
#    rerouting off the crater keeps inland terminals.
# SD outlets are base level: every outlet vertex ends at the input's height exactly. Control: with Outlet
#    Level 0 the same low vertices are no longer outlets and move.
# SE Max Slope is the threshold hillslope: no mesh edge stands steeper than Max Slope above a non-outlet
#    vertex. Control: with the limiter off the same run has edges far steeper.
# SF the mask scales the change cell by cell: where it is 0 the input passes through bit for bit and nothing
#    is eroded. Control: unmasked, the same cells move.
# SG the GDScript oracle is the specification: the native dictionary route equals solve_gd bit for bit on three
#    configurations (n = 1; n = 1.5 without routing noise; uplift, mask, dx/dy and Linear). Control: the oracle
#    with another seed differs.
# SH the compiled graph carries the op: native_supported, and graph_eval_grid equals both the forced GDScript
#    evaluator on the same graph and a graph of the [Dev/GD] oracle node. Control: the uplift unwired differs.
# SI the palette offers both Salève nodes by name, on their op ids.
# SJ Never Below Input keeps the result at or above the input: no cell ends lower, cells the run raised keep
#    the unclamped height bit for bit, and the oracle agrees bit for bit; through a compiled graph (the flag rides
#    the LUT) no cell ends below the source. Controls: off, cells end metres below the input, in both routes.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphSaleveStreamPowerGate.tscn
extends Node

const Dev := preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_saleve_stream_power.gd")
const Smooth := preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_hydraulic_saleve.gd")

const N := 96
const RECT := Rect2(-2000, -2000, 4000, 4000)
const CRITERIA := 10

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== GraphSaleveStreamPowerGate ===\n")
	_sa()
	_sb()
	_sc()
	_sd()
	_se()
	_sf()
	_sg()
	_sh()
	_si()
	_sj()
	_check(_ran == CRITERIA, "all %d criteria ran (%d)" % [CRITERIA, _ran])
	print("\n=== %s (%d failures) ===\n" % ["SALEVE STREAM POWER PASS" if _fail == 0 else "SALEVE STREAM POWER FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ---- fixtures -------------------------------------------------------------------------------------

## A 1500 m island: a 40 m dome with 3 m of ripple, sea at -20 m. `p_crater` sinks a 15 m bowl inland.
static func _island(p_n: int, p_crater := false) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_n * p_n)
	for iz in p_n:
		for ix in p_n:
			var x := RECT.position.x + (ix + 0.5) * RECT.size.x / p_n
			var z := RECT.position.y + (iz + 0.5) * RECT.size.y / p_n
			var r := sqrt(x * x + z * z)
			var h := -20.0
			if r < 1500.0:
				h = 40.0 * (1.0 - (r / 1500.0) * (r / 1500.0)) + 3.0 * sin(x / 170.0) * cos(z / 230.0)
				if p_crater:
					var c := Vector2(x - 400.0, z - 300.0).length()
					h -= 15.0 * exp(-c * c / (2.0 * 150.0 * 150.0))
			out[iz * p_n + ix] = h
	return out


## 0.25 at the west edge rising to 1 at the east.
static func _ramp(p_n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_n * p_n)
	for iz in p_n:
		for ix in p_n:
			out[iz * p_n + ix] = 0.25 + 0.75 * (ix + 0.5) / p_n
	return out


## 1 west of the centre, 0 east of it.
static func _half(p_n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_n * p_n)
	for iz in p_n:
		for ix in p_n:
			out[iz * p_n + ix] = 1.0 if ix < p_n / 2 else 0.0
	return out


static func _solve(p_src: PackedFloat32Array, p_extra: Dictionary) -> Dictionary:
	var p := {"control_points": 3000, "seed": 3}
	p.merge(p_extra, true)
	return Pasture3DUtil.saleve_stream_power_solve_grid(p_src, N, N, RECT, p)


## The solve's mesh, rebuilt by the shared oracle static (the native builds the same one: SG holds them together).
static func _mesh(p_src: PackedFloat32Array, p_cp := 3000, p_seed := 3) -> Dictionary:
	return Smooth._build_mesh(p_src, N, N, RECT, 0.0, p_cp, 100000, p_seed, 1.0)


static func _edge(p_mesh: Dictionary, p_a: int, p_b: int) -> float:
	return Smooth._edge_len(p_mesh.nbr_start, p_mesh.nbr, p_mesh.nbr_len, p_a, p_b)


static func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in p_a.size():
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w


static func _max(p_a: PackedFloat32Array) -> float:
	var w := 0.0
	for v in p_a:
		w = maxf(w, v)
	return w


static func _median(p_v: Array) -> float:
	if p_v.is_empty():
		return INF
	p_v.sort()
	return p_v[p_v.size() / 2]


# ---- criteria -------------------------------------------------------------------------------------

func _sa() -> void:
	print("[SA] a zero duration is the identity")
	var src := _island(N)
	var r := _solve(src, {"duration": 0.0})
	var same: bool = (r["height"] as PackedFloat32Array) == src
	_check(same and _max(r["eroded_rock"]) == 0.0 and int(r["steps"]) == 0,
			"duration 0: height bit-identical %s, eroded max %.4f, %d steps" % [same, _max(r["eroded_rock"]), r["steps"]])
	var d := _solve(src, {})
	var moved := _worst(d["height"], src)
	_check(moved > 1.0 and _max(d["eroded_rock"]) > 1.0, "control: the default run moves %.2f m and erodes %.2f m" % [moved, _max(d["eroded_rock"])])
	_ran += 1


## Median |S / S_pred - 1| over the vertices that drain to a receiver, S_pred from the law with the vertex's own
## uplift (or 1 with `p_ignore_u`).
func _law_error(p_res: Dictionary, p_mesh: Dictionary, p_m: float, p_n: float, p_g: float, p_a: float, p_ignore_u := false) -> Array:
	var z: PackedFloat32Array = p_res["vertex_height"]
	var rcv: PackedInt32Array = p_res["receivers"]
	var area: PackedFloat32Array = p_res["vertex_area"]
	var u: PackedFloat32Array = p_res["vertex_uplift"]
	var outl: PackedInt32Array = p_res["outlets"]
	var errs: Array = []
	for i in z.size():
		if outl[i] == 1 or rcv[i] == i:
			continue
		var u_i: float = 1.0 if p_ignore_u else u[i]
		var want: float = pow(u_i, 1.0 / p_n) * p_g * 1.0e-3 * pow(p_a / area[i], p_m / p_n)
		var got: float = (z[i] - z[rcv[i]]) / _edge(p_mesh, i, rcv[i])
		errs.append(absf(got / want - 1.0))
	return [_median(errs), errs.size()]


func _sb() -> void:
	print("[SB] the steady state is the stream-power law")
	var src := _island(N)
	var mesh := _mesh(src)
	var ramp := _ramp(N)
	var base := {"uplift": ramp, "max_slope": 20.0, "duration": 5000.0, "time_steps": 200, "debug_network": true}
	for n in [1.0, 1.5]:
		var p := base.duplicate()
		p["slope_exponent"] = n
		var r := _solve(src, p)
		var e := _law_error(r, mesh, 0.5, n, 300.0, 10000.0)
		_check(r["vertex_count"] == mesh.nv and e[0] <= 0.02 and e[1] > 1000,
				"n %.1f, 5 Myr: median slope error %.4f over %d vertices (<= 0.02)" % [n, e[0], e[1]])
		if n == 1.0:
			var ig := _law_error(r, mesh, 0.5, n, 300.0, 10000.0, true)
			_check(ig[0] > 0.2, "control: read against u = 1, the error is %.3f (> 0.2)" % ig[0])
	var short := base.duplicate()
	short["duration"] = 20.0
	short["time_steps"] = 4
	var es := _law_error(_solve(src, short), mesh, 0.5, 1.0, 300.0, 10000.0)
	_check(es[0] > 0.2, "control: 20 kyr is not at steady state, error %.3f (> 0.2)" % es[0])
	_ran += 1


## Inland vertices that are their own receiver without being an outlet.
static func _undrained(p_res: Dictionary) -> int:
	var rcv: PackedInt32Array = p_res["receivers"]
	var outl: PackedInt32Array = p_res["outlets"]
	var bad := 0
	for i in rcv.size():
		if rcv[i] == i and outl[i] == 0:
			bad += 1
	return bad


func _sc() -> void:
	print("[SC] every vertex drains to an outlet")
	var src := _island(N, true)
	var short := {"duration": 20.0, "time_steps": 10, "debug_network": true}
	var on := _undrained(_solve(src, short))
	_check(on == 0, "a cratered island: %d undrained terminals (0)" % on)
	var off_p := short.duplicate()
	off_p["reroute_lakes"] = false
	var off := _undrained(_solve(src, off_p))
	_check(off > 0, "control: rerouting off leaves %d undrained terminals" % off)
	_ran += 1


func _sd() -> void:
	print("[SD] outlets are base level")
	var src := _island(N)
	var input_v: PackedFloat32Array = _solve(src, {"duration": 0.0, "debug_network": true})["vertex_height"]
	var r := _solve(src, {"debug_network": true})
	var z: PackedFloat32Array = r["vertex_height"]
	var outl: PackedInt32Array = r["outlets"]
	var verts: PackedVector2Array = r["vertices"]
	var count := 0
	var worst := 0.0
	var low: Array[int] = [] # outlets by Outlet Level, off the boundary ring
	for i in z.size():
		if outl[i] == 1:
			count += 1
			worst = maxf(worst, absf(z[i] - input_v[i]))
			var v := verts[i]
			if v.x > RECT.position.x + 1.0 and v.y > RECT.position.y + 1.0 and v.x < RECT.end.x - 1.0 and v.y < RECT.end.y - 1.0:
				low.append(i)
	_check(count > 100 and low.size() > 100 and worst == 0.0, "%d outlets (%d by level) at the input's height, worst %.6f m" % [count, low.size(), worst])
	var z0: PackedFloat32Array = _solve(src, {"outlet_level": 0.0, "debug_network": true})["vertex_height"]
	var moved := 0
	for i in low:
		if absf(z0[i] - input_v[i]) > 0.01:
			moved += 1
	_check(moved > low.size() / 2, "control: with Outlet Level 0, %d of those %d move" % [moved, low.size()])
	_ran += 1


## The steepest rise, in m/m, of any non-outlet vertex above a neighbour, over Max Slope.
static func _worst_excess(p_res: Dictionary, p_mesh: Dictionary, p_cap: float) -> float:
	var z: PackedFloat32Array = p_res["vertex_height"]
	var outl: PackedInt32Array = p_res["outlets"]
	var ns: PackedInt32Array = p_mesh.nbr_start
	var nb: PackedInt32Array = p_mesh.nbr
	var nl: PackedFloat64Array = p_mesh.nbr_len
	var worst := -INF
	for j in z.size():
		if outl[j] == 1:
			continue
		for e in range(ns[j], ns[j + 1]):
			worst = maxf(worst, (z[j] - z[nb[e]]) / nl[e] - p_cap)
	return worst


func _se() -> void:
	print("[SE] Max Slope is the threshold hillslope")
	var src := _island(N)
	var mesh := _mesh(src)
	var p := {"max_slope": 0.05, "debug_network": true}
	var on := _worst_excess(_solve(src, p), mesh, 0.05)
	_check(on <= 1.0e-4, "Max Slope 0.05: the steepest edge exceeds it by %.6f m/m (<= 1e-4)" % on)
	p["limit_edges"] = false
	var off := _worst_excess(_solve(src, p), mesh, 0.05)
	_check(off > 0.05, "control: limiter off, an edge exceeds it by %.3f m/m" % off)
	_ran += 1


func _sf() -> void:
	print("[SF] the mask scales the change cell by cell")
	var src := _island(N)
	var mask := _half(N)
	var r := _solve(src, {"mask": mask})
	var unm := _solve(src, {})
	var h: PackedFloat32Array = r["height"]
	var e: PackedFloat32Array = r["eroded_rock"]
	var hu: PackedFloat32Array = unm["height"]
	var off_diff := 0.0
	var off_eroded := 0.0
	var ctrl := 0.0
	for i in src.size():
		if mask[i] == 0.0:
			off_diff = maxf(off_diff, absf(h[i] - src[i]))
			off_eroded = maxf(off_eroded, e[i])
			ctrl = maxf(ctrl, absf(hu[i] - src[i]))
	_check(off_diff == 0.0 and off_eroded == 0.0, "masked-off cells: height moves %.6f m, eroded %.6f m (both 0)" % [off_diff, off_eroded])
	_check(ctrl > 1.0, "control: unmasked, those cells move %.2f m" % ctrl)
	_ran += 1


func _sg() -> void:
	print("[SG] the native solve equals the GDScript oracle")
	var src := _island(N, true)
	var dx := PackedFloat32Array()
	dx.resize(N * N)
	for i in N * N:
		dx[i] = 15.0 * sin(i * 0.05)
	var cfgs := [
		{"control_points": 800, "time_steps": 20, "seed": 5},
		{"control_points": 800, "time_steps": 20, "slope_exponent": 1.5, "drainage_noise": 0.0, "drainage_exponent": 0.45},
		{"control_points": 800, "time_steps": 12, "uplift": _ramp(N), "mask": _ramp(N), "dx": dx, "dy": dx,
				"reconstruction": 0, "default_warp": false, "max_slope": 0.3, "outlet_level": 0.0},
	]
	for c in cfgs:
		var nat := Pasture3DUtil.saleve_stream_power_solve_grid(src, N, N, RECT, c)
		var ora: Array = Dev.solve_gd(src, N, N, RECT, c)
		var dh := _worst(nat["height"], ora[0])
		var de := _worst(nat["eroded_rock"], ora[1])
		var da := _worst(nat["drainage_area"], ora[2])
		_check(dh == 0.0 and de == 0.0 and da == 0.0 and int(nat["steps"]) == int(ora[3]["steps"]),
				"%s: |dh| %.6f, |de| %.6f, |dA| %.3f, steps %d/%d" % [str(c.keys()), dh, de, da, nat["steps"], ora[3]["steps"]])
	var other: Dictionary = (cfgs[0] as Dictionary).duplicate()
	other["seed"] = 6
	var cd := _worst(Pasture3DUtil.saleve_stream_power_solve_grid(src, N, N, RECT, cfgs[0])["height"], Dev.solve_gd(src, N, N, RECT, other)[0])
	_check(cd > 0.01, "control: the oracle with another seed differs by %.3f m" % cd)
	_ran += 1


## [graph, saleve id]: Mountain Cone -> `p_op`, Float to Mask (cone) on the mask and, with `p_uplift`, the uplift port.
func _graph(p_op: StringName, p_uplift: bool, p_floor := false) -> Array:
	var graph := Pasture3DTerrainGraph.create_empty()
	var cone = Pasture3DGraphNodeRegistry.create(&"mountain_cone")
	var ftm = Pasture3DGraphNodeRegistry.create(&"float_to_mask")
	ftm.set("in_max", 100.0)
	var sal = Pasture3DGraphNodeRegistry.create(p_op)
	sal.control_points = 900
	sal.time_steps = 16
	sal.duration = 200.0
	sal.slope_exponent = 1.25
	sal.never_below_input = p_floor
	var a: int = graph.add_node(cone)
	var b: int = graph.add_node(ftm)
	var c: int = graph.add_node(sal)
	graph.connect_ports(a, 0, b, 0)
	graph.connect_ports(a, 0, c, 0)
	graph.connect_ports(b, 0, c, sal.standard_mask_port())
	if p_uplift:
		graph.connect_ports(b, 0, c, 3)
	return [graph, c, a]


func _sh() -> void:
	print("[SH] the compiled graph carries the op")
	const GN := 64
	var rect := Rect2(0, 0, 1024, 1024)
	var g := _graph(&"saleve_stream_power", true)
	var graph: Pasture3DTerrainGraph = g[0]
	_check(graph.native_supported(g[1]), "native_supported")
	var nat: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(graph.compile_graph_program(g[1]), GN, GN, rect, PackedFloat32Array())
	var forced := _graph(&"saleve_stream_power", true)
	forced[0].force_gdscript_evaluation = true
	var gd: PackedFloat32Array = forced[0].evaluate(GN, GN, rect, null, PackedFloat32Array(), forced[1])
	var d := _worst(nat, gd)
	_check(d <= 1.0e-5, "native program against the forced GDScript evaluator: %.6f m" % d)
	var dev := _graph(&"dev_saleve_stream_power", true)
	dev[0].force_gdscript_evaluation = true
	var ora: PackedFloat32Array = dev[0].evaluate(GN, GN, rect, null, PackedFloat32Array(), dev[1])
	var dd := _worst(nat, ora)
	_check(dd <= 1.0e-5, "native program against the [Dev/GD] oracle graph: %.6f m" % dd)
	var g2 := _graph(&"saleve_stream_power", false)
	var nat2: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g2[0].compile_graph_program(g2[1]), GN, GN, rect, PackedFloat32Array())
	var d2 := _worst(nat, nat2)
	_check(d2 > 0.01, "control: uplift unwired differs by %.3f m" % d2)
	_ran += 1


func _si() -> void:
	print("[SI] both Salève nodes are in the palette by name")
	var titles := {}
	for e in Pasture3DGraphNodeRegistry.entries():
		titles[e["op"]] = e["title"]
	_check(titles.get(&"hydraulic_saleve", "") == "Salève Hydraulic Erosion Smooth", "hydraulic_saleve: \"%s\"" % titles.get(&"hydraulic_saleve", ""))
	_check(titles.get(&"saleve_stream_power", "") == "Salève Hydraulic Erosion", "saleve_stream_power: \"%s\"" % titles.get(&"saleve_stream_power", ""))
	var smooth = Pasture3DGraphNodeRegistry.create(&"hydraulic_saleve")
	var spl = Pasture3DGraphNodeRegistry.create(&"saleve_stream_power")
	_check(smooth.display_name() == "Salève Hydraulic Erosion Smooth" and spl.display_name() == "Salève Hydraulic Erosion",
			"display names \"%s\" / \"%s\"" % [smooth.display_name(), spl.display_name()])
	_check(titles.get(&"saleve_stream_power_smooth", "") == "", "control: no entry under an op id nobody registered")
	_ran += 1


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["PASS" if p_ok else "FAIL", p_msg])
	if not p_ok:
		_fail += 1


func _sj() -> void:
	print("[SJ] Never Below Input keeps the result at or above the input")
	var src := _island(N)
	var on := _solve(src, {"never_below_input": true})
	var off := _solve(src, {})
	var ho: PackedFloat32Array = on["height"]
	var hf: PackedFloat32Array = off["height"]
	var below := 0.0
	var raised_diff := 0.0
	var raised := 0
	var ctrl := 0.0
	for i in src.size():
		below = maxf(below, src[i] - ho[i])
		ctrl = maxf(ctrl, src[i] - hf[i])
		if hf[i] > src[i]:
			raised += 1
			raised_diff = maxf(raised_diff, absf(ho[i] - hf[i]))
	_check(below <= 0.0, "on: the lowest cell sits %.6f m below the input (<= 0)" % below)
	_check(raised > 0 and raised_diff == 0.0, "on: %d raised cells keep the unclamped height (|d| %.6f m)" % [raised, raised_diff])
	_check(ctrl > 1.0, "control: off, a cell ends %.2f m below the input" % ctrl)
	var c := {"control_points": 800, "time_steps": 12, "never_below_input": true, "mask": _ramp(N)}
	var ora: Array = Dev.solve_gd(src, N, N, RECT, c)
	var dh := _worst(Pasture3DUtil.saleve_stream_power_solve_grid(src, N, N, RECT, c)["height"], ora[0])
	_check(dh == 0.0, "the oracle with the floor and a mask: |dh| %.6f m" % dh)

	const GN := 64
	var rect := Rect2(0, 0, 1024, 1024)
	var res := []
	for flag in [true, false]:
		var g := _graph(&"saleve_stream_power", true, flag)
		res.append(Pasture3DUtil.graph_eval_grid(g[0].compile_graph_program(g[1]), GN, GN, rect, PackedFloat32Array()))
	var g0 := _graph(&"saleve_stream_power", true)
	var cone: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g0[0].compile_graph_program(g0[2]), GN, GN, rect, PackedFloat32Array())
	var gb := 0.0
	var gc := 0.0
	for i in cone.size():
		gb = maxf(gb, cone[i] - res[0][i])
		gc = maxf(gc, cone[i] - res[1][i])
	_check(gb <= 0.0, "compiled graph, on: the lowest cell sits %.6f m below the source (<= 0)" % gb)
	_check(gc > 0.1, "control: compiled graph, off, a cell ends %.3f m below the source" % gc)
	_ran += 1
