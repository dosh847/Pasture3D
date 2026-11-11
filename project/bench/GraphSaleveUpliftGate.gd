# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSaleveUpliftGate — Salève Stage 1 Mode UPLIFT (PASTURE3D_RANGES_SPEC.md step 4).
#
# UA INPUT mode is bit-identical to the build before UPLIFT existed: the direct solve's three outputs and a
#    compiled graph with a wired mask (the mask moved from in3 to in_aux) hash to values pinned on that
#    build. Control: UPLIFT mode differs.
# UB Stage 1's steady-state relief scales as uplift_gradient^(1/n): doubling it multiplies the summed vertex
#    height above the outlets (the sea, at the input's minimum) by 2 at n = 1 and by sqrt(2) at n = 2, within
#    2 %, at 600 and 1200 m/km. (Rise above the INPUT does not scale: the input is a fixed term in it; and
#    a low gradient leaves the steady state under the input near the coast, where max(input, ...) holds
#    it: 200 -> 400 m/km read 1.80 at n = 1.) Control: INPUT mode does
#    not move at all.
# UC follows the uplift field: a ring of uplift raises land inside the ring more than 3x the land outside
#    it. Control: uniform uplift does not.
# UD drains: every Stage 1 vertex reaches an outlet by its receivers, on an input with a crater. Control:
#    with lake rerouting off the crater is a terminal that is not an outlet.
# UE resolution invariance on a field metric (resolution-invariance-needs-field-metric): the 96² solve,
#    sampled at the 192² cell centres, is within 1.25 % RMS of the relief. Control: another seed at the
#    same resolution is not (the dome dominates the field, so a seed moves it only ~2 %; the threshold sits
#    between the two).
# UF the control-point cap holds: with point_spacing 5 m and max_control_points 2000, UPLIFT uses exactly
#    INPUT's lattice. Control: a cap of 8000 gives more points.
# UG the compiled graph carries UPLIFT, the uplift port and the mask: native_supported, and graph_eval_grid
#    equals the node's own dictionary route. Control: the same graph with uplift unwired differs.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphSaleveUpliftGate.tscn
extends Node

const HydraulicSaleve = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_hydraulic_saleve.gd")

# Pinned 2026-11-11 on 0542dfb4 (before UPLIFT), by this gate's own fixtures.
const PIN_DIRECT := [3867432826, 242468687, 1319576236]
const PIN_GRAPH := 632680851

const N := 128
const RECT := Rect2(-2000, -2000, 4000, 4000)

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("=== GraphSaleveUpliftGate ===\n")
	_ua()
	_ub()
	_uc()
	_ud()
	_ue()
	_uf()
	_ug()
	_check(_ran == 7, "all 7 criteria ran (%d)" % _ran)
	print("\n=== %s (%d failures) ===\n" % ["SALEVE UPLIFT PASS" if _fail == 0 else "SALEVE UPLIFT FAIL", _fail])
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


## 1 inside the ring 600..1100 m from the centre, else 0.
static func _ring(p_n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_n * p_n)
	for iz in p_n:
		for ix in p_n:
			var x := RECT.position.x + (ix + 0.5) * RECT.size.x / p_n
			var z := RECT.position.y + (iz + 0.5) * RECT.size.y / p_n
			var r := sqrt(x * x + z * z)
			out[iz * p_n + ix] = 1.0 if r > 600.0 and r < 1100.0 else 0.0
	return out


static func _solve(p_src: PackedFloat32Array, p_n: int, p_extra: Dictionary) -> Dictionary:
	var p := {"control_points": 3000, "seed": 3}
	p.merge(p_extra, true)
	return Pasture3DUtil.hydraulic_saleve_solve_grid(p_src, p_n, p_n, RECT, p)


static func _h(p_arr: PackedFloat32Array) -> int:
	return hash(p_arr.to_byte_array())


## Summed Stage 1 relief over the vertices: the debug_network surface above the outlets' level (the sea, the
## input's minimum). Max Slope is lifted out of reach so the cap does not saturate the shape.
static func _relief(p_src: PackedFloat32Array, p_extra: Dictionary) -> float:
	var base := {"erosion_strength": 1.0, "max_slope_center": 20.0, "max_slope_border": 20.0, "debug_network": true}
	base.merge(p_extra, true)
	var up: PackedFloat32Array = _solve(p_src, N, base)["vertex_height"]
	var lo := INF
	for v in p_src:
		lo = minf(lo, v)
	var s := 0.0
	for v in up:
		s += v - lo
	return s


# ---- criteria -------------------------------------------------------------------------------------

func _ua() -> void:
	print("[UA] INPUT mode is bit-identical to the pinned build")
	var src := _island(N)
	var res := _solve(src, N, {})
	var got := [_h(res["height"]), _h(res["eroded_rock"]), _h(res["sediment"])]
	_check(got == PIN_DIRECT, "direct solve %s (pinned %s)" % [got, PIN_DIRECT])
	var g := _graph(true, false, HydraulicSaleve.Stage1Mode.INPUT)
	var nat: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g[0].compile_graph_program(g[3]), N, N, Rect2(0, 0, 256, 256), PackedFloat32Array())
	_check(_h(nat) == PIN_GRAPH, "graph with a wired mask %d (pinned %d)" % [_h(nat), PIN_GRAPH])
	var up := _solve(src, N, {"stage1_mode": 1})
	_check(_h(up["height"]) != PIN_DIRECT[0], "control: UPLIFT differs (%d)" % _h(up["height"]))
	_ran += 1


func _ub() -> void:
	print("[UB] the relief scales as uplift_gradient^(1/n)")
	var src := _island(N)
	for n in [1.0, 2.0]:
		var r1 := _relief(src, {"stage1_mode": 1, "uplift_n": n, "uplift_gradient": 600.0})
		var r2 := _relief(src, {"stage1_mode": 1, "uplift_n": n, "uplift_gradient": 1200.0})
		var want := pow(2.0, 1.0 / n)
		var got := r2 / r1
		_check(r1 > 0.0 and absf(got / want - 1.0) <= 0.02, "n %.0f: ratio %.4f (want %.4f within 2 %%)" % [n, got, want])
	var a: PackedFloat32Array = _solve(src, N, {"uplift_gradient": 600.0})["height"]
	var b: PackedFloat32Array = _solve(src, N, {"uplift_gradient": 1200.0})["height"]
	_check(a == b, "control: INPUT mode does not move with the gradient")
	_ran += 1


## Mean rise of the final height over the input, on land, inside and outside the ring.
func _ring_ratio(p_src: PackedFloat32Array, p_uplift: PackedFloat32Array) -> float:
	var h: PackedFloat32Array = _solve(p_src, N, {"stage1_mode": 1, "erosion_strength": 1.0, "uplift": p_uplift})["height"]
	var ring := _ring(N)
	var si := 0.0
	var ni := 0
	var so := 0.0
	var no := 0
	for i in h.size():
		if p_src[i] <= 0.0:
			continue
		if ring[i] > 0.5:
			si += h[i] - p_src[i]
			ni += 1
		else:
			so += h[i] - p_src[i]
			no += 1
	return (si / maxf(ni, 1)) / maxf(so / maxf(no, 1), 1e-6)


func _uc() -> void:
	print("[UC] the range follows the uplift field")
	var src := _island(N)
	var ring := _ring_ratio(src, _ring(N))
	_check(ring > 3.0, "ring uplift: inside / outside mean rise %.2f (> 3)" % ring)
	var uni := PackedFloat32Array()
	uni.resize(N * N)
	uni.fill(1.0)
	var u := _ring_ratio(src, uni)
	_check(u <= 3.0, "control: uniform uplift gives %.2f (<= 3)" % u)
	_ran += 1


## Vertices whose receiver chain ends somewhere other than an outlet (an outlet is its own receiver and sits
## on the sea or the boundary ring; a pit is its own receiver inland).
static func _undrained(p_res: Dictionary, p_src: PackedFloat32Array) -> int:
	var rcv: PackedInt32Array = p_res["receivers"]
	var verts: PackedVector2Array = p_res["vertices"]
	var bad := 0
	for i in rcv.size():
		if rcv[i] != i:
			continue
		var v := verts[i]
		var ix := clampi(int((v.x - RECT.position.x) / RECT.size.x * N), 0, N - 1)
		var iz := clampi(int((v.y - RECT.position.y) / RECT.size.y * N), 0, N - 1)
		var on_ring := v.x <= RECT.position.x + 1.0 or v.y <= RECT.position.y + 1.0 \
				or v.x >= RECT.end.x - 1.0 or v.y >= RECT.end.y - 1.0
		if not on_ring and p_src[iz * N + ix] > 0.0:
			bad += 1
	return bad


func _ud() -> void:
	print("[UD] every vertex drains to an outlet")
	var src := _island(N, true)
	var on := _undrained(_solve(src, N, {"stage1_mode": 1, "debug_network": true}), src)
	_check(on == 0, "UPLIFT on a cratered island: %d inland terminals (0)" % on)
	var off := _undrained(_solve(src, N, {"stage1_mode": 1, "debug_network": true, "reroute_lakes": false}), src)
	_check(off > 0, "control: rerouting off leaves %d inland terminals" % off)
	_ran += 1


## RMS of (coarse solve, bilinear at the fine centres) - fine solve, over the fine solve's land relief.
static func _res_rms(p_coarse: PackedFloat32Array, p_nc: int, p_fine: PackedFloat32Array, p_nf: int) -> float:
	var img := Image.create_from_data(p_nc, p_nc, false, Image.FORMAT_RF, p_coarse.to_byte_array())
	var s := 0.0
	var lo := INF
	var hi := -INF
	for iz in p_nf:
		for ix in p_nf:
			var fx := (ix + 0.5) * p_nc / float(p_nf) - 0.5
			var fz := (iz + 0.5) * p_nc / float(p_nf) - 0.5
			var x0 := clampi(int(floor(fx)), 0, p_nc - 1)
			var z0 := clampi(int(floor(fz)), 0, p_nc - 1)
			var x1 := mini(x0 + 1, p_nc - 1)
			var z1 := mini(z0 + 1, p_nc - 1)
			var tx := clampf(fx - x0, 0.0, 1.0)
			var tz := clampf(fz - z0, 0.0, 1.0)
			var c := lerpf(lerpf(img.get_pixel(x0, z0).r, img.get_pixel(x1, z0).r, tx),
					lerpf(img.get_pixel(x0, z1).r, img.get_pixel(x1, z1).r, tx), tz)
			var f := p_fine[iz * p_nf + ix]
			s += (c - f) * (c - f)
			lo = minf(lo, f)
			hi = maxf(hi, f)
	return sqrt(s / (p_nf * p_nf)) / maxf(hi - lo, 1e-6)


func _ue() -> void:
	print("[UE] resolution invariance on the field")
	var p := {"stage1_mode": 1, "erosion_strength": 1.0, "point_spacing": 50.0, "stream_strength": 0.0}
	var c: PackedFloat32Array = _solve(_island(96), 96, p)["height"]
	var f: PackedFloat32Array = _solve(_island(192), 192, p)["height"]
	var o: PackedFloat32Array = _solve(_island(192), 192, p.merged({"seed": 11}, true))["height"]
	var d := _res_rms(c, 96, f, 192)
	_check(d <= 0.0125, "96² against 192²: RMS %.4f of the relief (<= 0.0125)" % d)
	var dc := _res_rms(c, 96, o, 192)
	_check(dc > 0.0125, "control: another seed at 192² reads %.4f (> 0.0125)" % dc)
	_ran += 1


func _uf() -> void:
	print("[UF] the control-point cap holds")
	var src := _island(N)
	var p := {"point_spacing": 5.0, "max_control_points": 2000}
	var a: int = _solve(src, N, p)["vertex_count"]
	var b: int = _solve(src, N, p.merged({"stage1_mode": 1}, true))["vertex_count"]
	_check(a == b and b > 0 and b < 2600, "INPUT %d, UPLIFT %d vertices (equal, cap 2000 + ring)" % [a, b])
	var c: int = _solve(src, N, p.merged({"stage1_mode": 1, "max_control_points": 8000}, true))["vertex_count"]
	_check(c > b, "control: a cap of 8000 gives %d" % c)
	_ran += 1


## [graph, cone id, float_to_mask id, saleve id]: Mountain Cone -> Salève, with Float to Mask (cone) wired to
## the mask and/or the uplift port.
func _graph(p_mask: bool, p_uplift: bool, p_mode: int) -> Array:
	var graph := Pasture3DTerrainGraph.create_empty()
	var cone = Pasture3DGraphNodeRegistry.create(&"mountain_cone")
	var ftm = Pasture3DGraphNodeRegistry.create(&"float_to_mask")
	ftm.set("in_max", 100.0)
	var sal = Pasture3DGraphNodeRegistry.create(&"hydraulic_saleve")
	sal.control_points = 2500
	sal.stage1_mode = p_mode
	var a: int = graph.add_node(cone)
	var b: int = graph.add_node(ftm)
	var c: int = graph.add_node(sal)
	graph.connect_ports(a, 0, b, 0)
	graph.connect_ports(a, 0, c, 0)
	if p_mask:
		graph.connect_ports(b, 0, c, sal.standard_mask_port())
	if p_uplift:
		graph.connect_ports(b, 0, c, 3)
	return [graph, a, b, c, sal]


func _ug() -> void:
	print("[UG] the compiled graph carries UPLIFT")
	var rect := Rect2(0, 0, 256, 256)
	var g := _graph(true, true, HydraulicSaleve.Stage1Mode.UPLIFT)
	var graph: Pasture3DTerrainGraph = g[0]
	_check(graph.native_supported(g[3]), "native_supported")
	var nat: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(graph.compile_graph_program(g[3]), N, N, rect, PackedFloat32Array())
	var surf: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(graph.compile_graph_program(g[1]), N, N, rect, PackedFloat32Array())
	var msk: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(graph.compile_graph_program(g[2]), N, N, rect, PackedFloat32Array())
	var own: PackedFloat32Array = g[4]._solve_dynamic(surf, N, N, rect, PackedFloat32Array(), PackedFloat32Array(), msk, msk)[0]
	var d := 0.0
	for i in mini(nat.size(), own.size()):
		d = maxf(d, absf(nat[i] - own[i]))
	_check(nat.size() == N * N and d < 1e-4, "native against the node's dictionary route: %.6f m" % d)
	var g2 := _graph(true, false, HydraulicSaleve.Stage1Mode.UPLIFT)
	var nat2: PackedFloat32Array = Pasture3DUtil.graph_eval_grid(g2[0].compile_graph_program(g2[3]), N, N, rect, PackedFloat32Array())
	var d2 := 0.0
	for i in mini(nat.size(), nat2.size()):
		d2 = maxf(d2, absf(nat[i] - nat2[i]))
	_check(d2 > 0.01, "control: uplift unwired differs by %.3f m" % d2)
	_ran += 1


func _check(p_ok: bool, p_msg: String) -> void:
	print("  %s %s" % ["PASS" if p_ok else "FAIL", p_msg])
	if not p_ok:
		_fail += 1
