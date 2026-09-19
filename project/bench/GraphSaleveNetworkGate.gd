# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphSaleveNetworkGate: phase S1 of PASTURE3D_SALEVE_STRATA_FIDELITY_SPEC.md — the Salève drainage
# network is one connected tree per border outlet.
#
#   A  every cell's receiver chain ends at a border outlet (cells checked == n)
#   B  an interior pit is rerouted; control: reroute_lakes off leaves >= 1 interior terminal
#   C  the solve converges before its iteration budget; control: per-pass routing noise does not
#   D  drainage area at the outlets sums to the domain area; control: reroute_lakes off loses area to pits
#
# Asserts on the solver's own receivers (debug_network), not on anything this gate computes for it.

extends Node

const GW := 64
const GH := 64
const RECT := Rect2(0, 0, 256, 256)
const EXPECTED := 4

var _fail := 0
var _done := 0
var _verts := PackedVector2Array() # the solve's vertices (S2 mesh); border == on the rect's edge


func _ready() -> void:
	print("=== GraphSaleveNetworkGate: Salève S1 drainage network ===\n")
	_a_chains_reach_outlets()
	_b_pit_rerouted()
	_c_converges()
	_d_area_conserved()
	var ok := _fail == 0 and _done == EXPECTED
	print("\n=== %s (%d failures, %d/%d criteria completed) ===" % [
		"SALEVE NETWORK PASS" if ok else "SALEVE NETWORK FAIL", _fail, _done, EXPECTED])
	get_tree().quit(0 if ok else 1)


func _a_chains_reach_outlets() -> void:
	print("[A] every receiver chain ends at a border outlet (cratered dome, full solve)")
	var res := _solve(_crater(), {"iterations": 60})
	var rec: PackedInt32Array = res.receivers
	var reached := _cells_reaching_border(rec)
	print("    vertices reaching a border outlet: %d / %d" % [reached, rec.size()])
	if reached != rec.size() or rec.size() < 100:
		_fail += 1
		print("    !! %d vertices drain to an interior terminal or a cycle" % (rec.size() - reached))
		return
	_done += 1


func _b_pit_rerouted() -> void:
	print("\n[B] an interior pit drains out (one pass, receivers straight off the input)")
	var on := _solve(_crater(), {"iterations": 1})
	var off := _solve(_crater(), {"iterations": 1, "reroute_lakes": false})
	var t_on := _interior_terminals(on.receivers)
	var t_off := _interior_terminals(off.receivers)
	print("    interior terminals: reroute on %d (want 0), control reroute off %d (want >= 1)" % [t_on, t_off])
	if t_off < 1:
		_fail += 1
		print("    !! the fixture has no pit, so this criterion measured nothing")
		return
	if t_on != 0:
		_fail += 1
		print("    !! rerouting left interior terminals")
		return
	_done += 1


func _c_converges() -> void:
	print("\n[C] the solve converges below tolerance before its budget")
	var budget := 200
	var stable := _solve(_crater(), {"iterations": budget, "tolerance": 1.0e-3})
	var noisy := _solve(_crater(), {"iterations": budget, "tolerance": 1.0e-3, "stable_noise": false,
			"drainage_noise": 0.5})
	var stable_noisy := _solve(_crater(), {"iterations": budget, "tolerance": 1.0e-3, "drainage_noise": 0.5})
	print("    passes: stable noise %d, stable noise at drainage_noise 0.5 %d (want < %d);"
			% [stable.iterations, stable_noisy.iterations, budget]
			+ " control per-pass noise %d (want == %d)" % [noisy.iterations, budget])
	if int(noisy.iterations) < budget:
		_fail += 1
		print("    !! per-pass noise converged too, so convergence does not show the noise is stable")
		return
	if int(stable.iterations) >= budget or int(stable_noisy.iterations) >= budget:
		_fail += 1
		print("    !! the stable solve ran out of budget")
		return
	_done += 1


func _d_area_conserved() -> void:
	print("\n[D] drainage area at the border outlets sums to the domain area")
	var on := _solve(_crater(), {"iterations": 1})
	var off := _solve(_crater(), {"iterations": 1, "reroute_lakes": false})
	var domain: float = float(GW * GH) * float(on.cell_area)
	var a_on := _border_outlet_area(on)
	var a_off := _border_outlet_area(off)
	var rel_on := absf(a_on - domain) / domain
	var rel_off := absf(a_off - domain) / domain
	print("    |outlet area - domain| / domain: reroute on %.7f (want < 0.0001), control off %.7f (want > 0.001)"
			% [rel_on, rel_off])
	if rel_off <= 1.0e-3:
		_fail += 1
		print("    !! the control lost no area to pits, so conservation here proves nothing")
		return
	if rel_on >= 1.0e-4:
		_fail += 1
		print("    !! area is not conserved at the outlets")
		return
	_done += 1


# ---- helpers ------------------------------------------------------------------------------------

func _solve(p_surface: PackedFloat32Array, p_extra: Dictionary) -> Dictionary:
	# Border-only outlets (outlet_level 0): this gate is about routing TO the border. The default also drains
	# the low ground, where the crater floor would itself be an outlet; SaleveMarginInvarianceProbe covers that.
	var params := {"seed": 7, "debug_network": true, "control_points": 3000, "outlet_level": 0.0}
	params.merge(p_extra, true)
	var r: Dictionary = Pasture3DUtil.hydraulic_saleve_solve_grid(p_surface, GW, GH, RECT, params)
	_verts = r.get("vertices", PackedVector2Array())
	return r


# A dome with a crater at its centre: the crater floor is a pit the plain D8 network cannot leave.
func _crater() -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GW * GH)
	for iz in range(GH):
		for ix in range(GW):
			var u := (float(ix) + 0.5) / GW - 0.5
			var v := (float(iz) + 0.5) / GH - 0.5
			var r := sqrt(u * u + v * v)
			var h := 60.0 * cos(minf(r / 0.5, 1.0) * PI * 0.5)
			h -= 40.0 * exp(-(r * r) / (0.08 * 0.08))
			a[iz * GW + ix] = h
	return a


func _is_border(p_idx: int) -> bool:
	var v := _verts[p_idx]
	return v.x <= RECT.position.x or v.y <= RECT.position.y or v.x >= RECT.end.x or v.y >= RECT.end.y


func _cells_reaching_border(p_rec: PackedInt32Array) -> int:
	var n := p_rec.size()
	var count := 0
	for i in range(n):
		var c := i
		var steps := 0
		while p_rec[c] != c and steps <= n:
			c = p_rec[c]
			steps += 1
		if p_rec[c] == c and _is_border(c):
			count += 1
	return count


func _interior_terminals(p_rec: PackedInt32Array) -> int:
	var t := 0
	for i in range(p_rec.size()):
		if p_rec[i] == i and not _is_border(i):
			t += 1
	return t


func _border_outlet_area(p_res: Dictionary) -> float:
	var rec: PackedInt32Array = p_res.receivers
	var area: PackedFloat32Array = p_res.drainage_area
	var s := 0.0
	for i in range(rec.size()):
		if rec[i] == i and _is_border(i):
			s += area[i]
	return s
