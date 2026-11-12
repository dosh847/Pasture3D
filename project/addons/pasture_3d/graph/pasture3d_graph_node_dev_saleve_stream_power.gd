# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevSaleveStreamPower — pure GDScript reference oracle for Salève Hydraulic Erosion (uplift and
# stream-power incision). It is the specification: src/pasture_3d_hydraulic_saleve.cpp (saleve_stream_power_solve)
# mirrors it, float32 roundings included, and GraphSaleveStreamPowerGate holds the two together.
#
# The mesh, the reconstruction, the lake rerouting and the edge limiter are the Smooth oracle's statics
# (Pasture3DGraphNodeDevHydraulicSaleve), so the two nodes share one implementation of each, as their native
# solves share one kernel.

@tool
class_name Pasture3DGraphNodeDevSaleveStreamPower
extends Pasture3DGraphSolverNode

const Smooth := preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_hydraulic_saleve.gd")

@export_group("Uplift")
@export_range(0.0, 20.0, 0.01, "or_greater", "suffix:mm/yr") var uplift_rate: float = 1.0:
	set(v):
		uplift_rate = maxf(v, 0.0)
		_param_changed()
@export_range(0.0, 10000.0, 1.0, "or_greater", "suffix:kyr") var duration: float = 500.0:
	set(v):
		duration = maxf(v, 0.0)
		_param_changed()
@export_range(1, 1000, 1, "or_greater") var time_steps: int = 100:
	set(v):
		time_steps = maxi(v, 1)
		_param_changed()
@export_group("Stream Power")
@export_range(0.0, 2000.0, 1.0, "or_greater", "suffix:m/km") var uplift_gradient: float = 300.0:
	set(v):
		uplift_gradient = maxf(v, 0.0)
		_param_changed()
@export_range(1.0, 1000000.0, 1.0, "or_greater", "suffix:m²") var channel_area: float = 10000.0:
	set(v):
		channel_area = maxf(v, 1.0)
		_param_changed()
@export_range(0.05, 2.0, 0.01) var drainage_exponent: float = 0.5:
	set(v):
		drainage_exponent = clampf(v, 0.05, 2.0)
		_param_changed()
@export_range(0.5, 4.0, 0.05) var slope_exponent: float = 1.0:
	set(v):
		slope_exponent = clampf(v, 0.5, 4.0)
		_param_changed()
@export_range(0.0, 20.0, 0.05, "or_greater", "suffix:m/m") var max_slope: float = 1.0:
	set(v):
		max_slope = maxf(v, 0.0)
		_param_changed()
@export_range(0.0, 1.0, 0.01) var drainage_noise: float = 0.15:
	set(v):
		drainage_noise = clampf(v, 0.0, 1.0)
		_param_changed()
@export_range(0.0, 0.5, 0.005) var outlet_level: float = 0.1:
	set(v):
		outlet_level = clampf(v, 0.0, 0.5)
		_param_changed()
@export_range(0.0, 1.0, 0.01) var strength: float = 1.0:
	set(v):
		strength = clampf(v, 0.0, 1.0)
		_param_changed()
@export var never_below_input: bool = false:
	set(v):
		never_below_input = v
		_param_changed()
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()
@export_group("Control Points")
@export_range(500, 100000, 100) var control_points: int = 15000:
	set(v):
		control_points = clampi(v, 16, 100000)
		_param_changed()
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m") var point_spacing: float = 0.0:
	set(v):
		point_spacing = maxf(v, 0.0)
		_param_changed()
enum Reconstruction { LINEAR, GRADIENT }
@export var reconstruction: Reconstruction = Reconstruction.GRADIENT:
	set(v):
		reconstruction = v
		_param_changed()
@export_group("Warp")
@export var default_warp: bool = true:
	set(v):
		default_warp = v
		_param_changed()
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m") var warp_amount: float = 0.0:
	set(v):
		warp_amount = maxf(v, 0.0)
		_param_changed()
@export_range(0.0, 1000.0, 1.0, "or_greater", "suffix:m") var warp_size: float = 0.0:
	set(v):
		warp_size = maxf(v, 0.0)
		_param_changed()

@export_group("Evaluation")
@export_tool_button("Bake Salève Erosion") var _bake_btn = clear_cache


func _init() -> void:
	super()


func bake_label() -> String:
	return "Bake Salève Erosion"


func op() -> StringName:
	return &"dev_saleve_stream_power"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "[Dev/GD] Salève Hydraulic Erosion"


func needs_grid() -> bool:
	return true


func mask_mode() -> MaskMode:
	return MaskMode.OWN


func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"in", PortType.HEIGHT).require(),
		Pasture3DGraphPort.field(&"dx", PortType.SIGNED),
		Pasture3DGraphPort.field(&"dy", PortType.SIGNED),
		Pasture3DGraphPort.field(&"uplift", PortType.MASK).unwired(1.0),
	]


func _outputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"height", PortType.HEIGHT),
		Pasture3DGraphPort.field(&"eroded_rock", PortType.FIELD),
		Pasture3DGraphPort.field(&"drainage_area", PortType.FIELD),
	]


func params_dict() -> Dictionary:
	return {
		"uplift_rate": uplift_rate, "duration": duration, "time_steps": time_steps,
		"uplift_gradient": uplift_gradient, "channel_area": channel_area,
		"drainage_exponent": drainage_exponent, "slope_exponent": slope_exponent, "max_slope": max_slope,
		"drainage_noise": drainage_noise, "outlet_level": outlet_level, "strength": strength,
		"never_below_input": never_below_input, "seed": seed,
		"control_points": control_points, "point_spacing": point_spacing, "reconstruction": int(reconstruction),
		"default_warp": default_warp, "warp_amount": warp_amount, "warp_size": warp_size,
	}


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var grids: Array = []
	for k in 5:
		grids.append((p_inputs[k] as PackedFloat32Array) if (p_inputs.size() > k and p_inputs[k] is PackedFloat32Array) else PackedFloat32Array())
	var surface: PackedFloat32Array = grids[0] if (grids[0] as PackedFloat32Array).size() == n else Pasture3DGraphOps.zeros(n)
	var p := params_dict()
	p["dx"] = grids[1]
	p["dy"] = grids[2]
	p["uplift"] = grids[3]
	p["mask"] = grids[4]
	var r: Array = solve_cached(solver_cache_key(p_gw, p_gh, [surface, grids[1], grids[2], grids[3], grids[4]]),
			func(): return solve_gd(surface, p_gw, p_gh, p_rect, p))
	return [r[0], r[1], r[2]]


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func _param_changed() -> void:
	mark_dirty_since_bake()
	emit_changed()


# ---- Pure GDScript reference oracle --------------------------------------------------------------------------------

## The float32 rounding of a double: the native solve stores its params and heights as floats.
static func _f32(p_v: float) -> float:
	return PackedFloat32Array([p_v])[0]


## Steepest-descent receivers on `z` with no input fan (the native saleve_route, p_fan null): any lower neighbour,
## scored by slope plus seeded noise, in float32 as the native does it.
static func _route_free(nbr_start: PackedInt32Array, nbr: PackedInt32Array, nbr_len: PackedFloat64Array,
		outlet: PackedByteArray, z: PackedFloat32Array, p_noise: float, p_seed: int, r_receivers: PackedInt32Array) -> void:
	var nv: int = z.size()
	var f := PackedFloat32Array([0.0])
	for idx in range(nv):
		if outlet[idx] == 1:
			r_receivers[idx] = idx
			continue
		var best_score: float = -INF
		var best: int = idx
		for e in range(nbr_start[idx], nbr_start[idx + 1]):
			var n_idx: int = nbr[e]
			f[0] = z[idx] - z[n_idx]
			var dzf: float = f[0]
			f[0] = nbr_len[e]
			f[0] = dzf / f[0]
			var slope: float = f[0]
			if not (slope > 0.0):
				continue
			var noise: float = Smooth._fast_hash_to_unit(p_seed, idx ^ (n_idx << 16))
			f[0] = slope * p_noise
			f[0] = f[0] * noise
			f[0] = slope + f[0]
			var score: float = f[0]
			if score > best_score:
				best_score = score
				best = n_idx
		r_receivers[idx] = best


## One implicit stream-power step along the receiver (the native saleve_spl_implicit).
static func _spl_implicit(p_h0: float, p_hr: float, p_c: float, p_n: float) -> float:
	var x0: float = p_h0 - p_hr
	if not (x0 > 0.0) or not (p_c > 0.0):
		return p_h0
	if p_n == 1.0:
		return p_hr + x0 / (1.0 + p_c)
	var x: float = x0
	for _it in range(60):
		var gx: float = x - x0 + p_c * pow(x, p_n)
		var gd: float = 1.0 + p_c * p_n * pow(x, p_n - 1.0)
		var xn: float = x - gx / gd
		if not (xn > 0.0):
			xn = 0.5 * x
		var step: float = absf(xn - x)
		x = xn
		if step <= 1.0e-12 * x0:
			break
	return p_hr + x


## The solve. Returns [height, eroded_rock, drainage_area, info], info holding `steps`, `vertex_count` and, with
## params.debug_network, the vertex network (as the native result's debug fields).
static func solve_gd(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_params: Dictionary) -> Array:
	var n: int = p_gw * p_gh
	var info := {"steps": 0, "vertex_count": 0}
	if p_gw < 2 or p_gh < 2 or p_surface.size() != n:
		return [p_surface.duplicate(), PackedFloat32Array(), PackedFloat32Array(), info]
	var mask: PackedFloat32Array = p_params.get("mask", PackedFloat32Array())
	var uplift: PackedFloat32Array = p_params.get("uplift", PackedFloat32Array())
	var dx_arr: PackedFloat32Array = p_params.get("dx", PackedFloat32Array())
	var dy_arr: PackedFloat32Array = p_params.get("dy", PackedFloat32Array())
	var has_mask: bool = mask.size() == n
	var has_up: bool = uplift.size() == n

	# Params as the native sees them: float32, then clamped.
	var uplift_rate: float = _f32(float(p_params.get("uplift_rate", 1.0)))
	var duration: float = _f32(float(p_params.get("duration", 500.0)))
	var time_steps: int = int(p_params.get("time_steps", 100))
	var gradient: float = _f32(float(p_params.get("uplift_gradient", 300.0)))
	var m_param: float = _f32(float(p_params.get("drainage_exponent", 0.5)))
	var n_param: float = _f32(float(p_params.get("slope_exponent", 1.0)))
	var a_param: float = _f32(float(p_params.get("channel_area", 10000.0)))
	var max_slope: float = maxf(0.0, _f32(float(p_params.get("max_slope", 1.0))))
	var noise: float = maxf(0.0, _f32(float(p_params.get("drainage_noise", 0.15))))
	var p_seed: int = int(p_params.get("seed", 0))
	var outlet_level: float = clampf(_f32(float(p_params.get("outlet_level", 0.1))), 0.0, 1.0)
	var strength: float = clampf(_f32(float(p_params.get("strength", 1.0))), 0.0, 1.0)
	var floor_input: bool = bool(p_params.get("never_below_input", false))
	var control_points: int = clampi(int(p_params.get("control_points", 15000)), 16, 100000)
	var max_control_points: int = maxi(int(p_params.get("max_control_points", 100000)), 16)
	var point_spacing: float = maxf(0.0, _f32(float(p_params.get("point_spacing", 0.0))))
	var recon: int = clampi(int(p_params.get("reconstruction", 1)), 0, 2)
	var default_warp: bool = bool(p_params.get("default_warp", true))
	var warp_amount: float = _f32(float(p_params.get("warp_amount", 0.0)))
	var warp_size: float = _f32(float(p_params.get("warp_size", 0.0)))
	var reroute: bool = bool(p_params.get("reroute_lakes", true))
	var limit_edges: bool = bool(p_params.get("limit_edges", true))
	var debug: bool = bool(p_params.get("debug_network", false))

	var zmin: float = INF
	var zmax: float = -INF
	for v in p_surface:
		if is_finite(v):
			zmin = minf(zmin, v)
			zmax = maxf(zmax, v)
	var eroded_out := PackedFloat32Array()
	eroded_out.resize(n)
	var area_out := PackedFloat32Array()
	area_out.resize(n)
	if zmin > zmax:
		return [p_surface.duplicate(), eroded_out, area_out, info]
	var relief: float = zmax - zmin

	var mesh: Dictionary = Smooth._build_mesh(p_surface, p_gw, p_gh, p_rect, point_spacing, control_points,
			max_control_points, p_seed, 1.0)
	var nv: int = mesh.nv
	info["vertex_count"] = nv
	var px: PackedFloat64Array = mesh.px
	var pz: PackedFloat64Array = mesh.pz
	var vh: PackedFloat64Array = mesh.vh
	var outlet: PackedByteArray = mesh.outlet
	var area: PackedFloat64Array = mesh.area
	var nbr_start: PackedInt32Array = mesh.nbr_start
	var nbr: PackedInt32Array = mesh.nbr
	var nbr_len: PackedFloat64Array = mesh.nbr_len

	var x0: float = p_rect.position.x
	var z0: float = p_rect.position.y
	var rw: float = p_rect.size.x if p_rect.size.x > 0.0 else float(p_gw)
	var rh: float = p_rect.size.y if p_rect.size.y > 0.0 else float(p_gh)
	var cell_dx: float = rw / float(p_gw)
	var cell_dz: float = rh / float(p_gh)

	var low: float = zmin + outlet_level * relief
	var z := PackedFloat32Array()
	z.resize(nv)
	var u := PackedFloat32Array()
	u.resize(nv)
	u.fill(1.0)
	for i in range(nv):
		if not is_finite(vh[i]):
			z[i] = zmin
			outlet[i] = 1
			u[i] = 0.0
			continue
		z[i] = vh[i]
		if relief > 1.0e-5 and outlet_level > 0.0 and vh[i] <= low:
			outlet[i] = 1
		if has_up:
			var s: float = Smooth._sample(uplift, p_gw, p_gh, x0, z0, cell_dx, cell_dz, px[i], pz[i])
			u[i] = clampf(s, 0.0, 1.0) if is_finite(s) else 0.0
	var input_v: PackedFloat32Array = z.duplicate()

	var fseed: int = (p_seed ^ 0x9e3779b9) & 0xffffffff
	var rn := PackedFloat32Array()
	rn.resize(nv)
	for i in range(nv):
		rn[i] = 1.0e-3 * Smooth._value_noise(px[i] / 50.0, pz[i] / 50.0, fseed)

	var steps: int = clampi(time_steps, 1, 100000)
	var U: float = maxf(0.0, uplift_rate) * 1.0e-3
	var T: float = maxf(0.0, duration) * 1.0e3
	var dt: float = T / float(steps)
	var m_exp: float = clampf(m_param, 0.05, 2.0)
	var n_exp: float = clampf(n_param, 0.5, 4.0)
	var G: float = maxf(0.0, gradient) * 1.0e-3
	var a_ch: float = maxf(1.0, a_param)
	var K: float = U / (pow(G, n_exp) * pow(a_ch, m_exp)) if (G > 0.0 and U > 0.0) else 0.0

	var receivers := PackedInt32Array()
	receivers.resize(nv)
	var area_acc := PackedFloat32Array()
	area_acc.resize(nv)
	var order := PackedInt32Array()
	var zr := PackedFloat32Array()
	zr.resize(nv)
	var eroded := PackedFloat64Array()
	eroded.resize(nv)
	var no_input := PackedFloat32Array()
	no_input.resize(nv)
	var cap := PackedFloat32Array()
	cap.resize(nv)
	cap.fill(max_slope)
	var f := PackedFloat32Array([0.0])

	var run: bool = dt > 0.0 and U > 0.0
	for step in range(steps if run else 0):
		info["steps"] = step + 1
		order = _route_and_accumulate(mesh, outlet, z, rn, zr, noise, p_seed, reroute, receivers, area_acc)
		for k in range(nv):
			var i: int = order[k]
			if outlet[i] == 1:
				continue
			var h0: float = z[i] + dt * U * u[i]
			var r: int = receivers[i]
			if r == i:
				z[i] = h0
				continue
			var d: float = maxf(Smooth._edge_len(nbr_start, nbr, nbr_len, i, r), 1.0e-5)
			var c: float = dt * K * pow(area_acc[i], m_exp) / pow(d, n_exp)
			var h: float = _spl_implicit(h0, z[r], c, n_exp)
			eroded[i] += h0 - h
			z[i] = h
		if limit_edges:
			var before: PackedFloat32Array = z.duplicate()
			Smooth._limit_edges(nbr_start, nbr, nbr_len, outlet, z, no_input, cap, 0.0)
			for i in range(nv):
				eroded[i] += before[i] - z[i]
	order = _route_and_accumulate(mesh, outlet, z, rn, zr, noise, p_seed, reroute, receivers, area_acc)

	var dz := PackedFloat32Array()
	dz.resize(nv)
	var er := PackedFloat32Array()
	er.resize(nv)
	for i in range(nv):
		dz[i] = z[i] - input_v[i]
		er[i] = maxf(0.0, eroded[i])
	var recon_lin: int = 2 if recon == 2 else 0
	var dzg: PackedFloat32Array = Smooth._reconstruct(mesh, dz, p_gw, p_gh, p_rect, recon, dx_arr, dy_arr, default_warp,
			warp_amount, warp_size, p_seed, true)
	var erg: PackedFloat32Array = Smooth._reconstruct(mesh, er, p_gw, p_gh, p_rect, recon_lin, dx_arr, dy_arr, default_warp,
			warp_amount, warp_size, p_seed, true)
	var ag: PackedFloat32Array = Smooth._reconstruct(mesh, area_acc, p_gw, p_gh, p_rect, recon_lin, dx_arr, dy_arr,
			default_warp, warp_amount, warp_size, p_seed, true)

	var height: PackedFloat32Array = p_surface.duplicate()
	for i in range(n):
		if not is_finite(p_surface[i]):
			continue
		f[0] = strength * (clampf(mask[i], 0.0, 1.0) if has_mask else 1.0)
		var w: float = f[0]
		f[0] = w * (maxf(0.0, dzg[i]) if floor_input else dzg[i])
		f[0] = p_surface[i] + f[0]
		height[i] = f[0]
		f[0] = w * maxf(0.0, erg[i])
		eroded_out[i] = f[0]
		area_out[i] = maxf(0.0, ag[i])

	if debug:
		var verts := PackedVector2Array()
		verts.resize(nv)
		var outs := PackedInt32Array()
		outs.resize(nv)
		for i in range(nv):
			verts[i] = Vector2(px[i], pz[i])
			outs[i] = outlet[i]
		info["vertices"] = verts
		info["vertex_height"] = z
		info["receivers"] = receivers
		info["vertex_area"] = area_acc
		info["vertex_uplift"] = u
		info["outlets"] = outs
	return [height, eroded_out, area_out, info]


## Route on the surface plus the flat-breaking noise, spill the lakes, accumulate: the native route_and_accumulate.
## Returns the tree order (outlets first).
static func _route_and_accumulate(p_mesh: Dictionary, outlet: PackedByteArray, z: PackedFloat32Array,
		rn: PackedFloat32Array, zr: PackedFloat32Array, p_noise: float, p_seed: int, p_reroute: bool,
		receivers: PackedInt32Array, area_acc: PackedFloat32Array) -> PackedInt32Array:
	var nv: int = z.size()
	for i in range(nv):
		zr[i] = z[i] + rn[i]
	_route_free(p_mesh.nbr_start, p_mesh.nbr, p_mesh.nbr_len, outlet, zr, p_noise, p_seed, receivers)
	var tree: Dictionary = Smooth._build_tree(receivers, nv)
	if p_reroute:
		var any_pit: bool = false
		for i in range(nv):
			if receivers[i] == i and outlet[i] == 0:
				any_pit = true
				break
		if any_pit:
			Smooth._reroute_lakes(p_mesh.nbr_start, p_mesh.nbr, outlet, zr, receivers, tree.root_of)
			tree = Smooth._build_tree(receivers, nv)
	var order: PackedInt32Array = tree.order
	var area: PackedFloat64Array = p_mesh.area
	for i in range(nv):
		area_acc[i] = area[i]
	for k in range(nv - 1, -1, -1):
		var idx: int = order[k]
		var r: int = receivers[idx]
		if r != idx:
			area_acc[r] += area_acc[idx]
	return order
