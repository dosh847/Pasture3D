# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevErosionHydraulic — pure GDScript reference oracle for hydraulic erosion simulation.
# Used for algorithm prototyping, A/B testing, and automated headless CI parity verification.
@tool
class_name Pasture3DGraphNodeDevErosionHydraulic
extends Pasture3DGraphSolverNode


@export_group("Simulation")
@export_range(1, 100, 1, "or_greater") var iterations: int = 25:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

@export_range(0.001, 0.5, 0.005, "or_greater") var rain_rate: float = 0.05:
	set(v):
		rain_rate = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 1.0, 0.005) var evaporation_rate: float = 0.02:
	set(v):
		evaporation_rate = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.1, 50.0, 0.5, "or_greater") var sediment_capacity: float = 8.0:
	set(v):
		sediment_capacity = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var erosion_speed: float = 0.5:
	set(v):
		erosion_speed = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var deposition_speed: float = 0.4:
	set(v):
		deposition_speed = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.0, 0.5, 0.005) var min_slope: float = 0.01:
	set(v):
		min_slope = maxf(v, 0.0)
		_param_changed()

## WALLS: the grid edge and no-data cells hold water in, so it ponds and drops its sediment along them.
## The original behaviour. OUTLETS: water reaching them drains away, as into terrain beyond the grid that
## sits Outlet Level below the rim. Only the rim changes: the interior is identical to WALLS until the
## drainage it feeds reaches it, one cell per iteration.
@export_enum("Walls", "Outlets") var edge_mode: int = 0:
	set(v):
		edge_mode = clampi(v, 0, 1)
		_param_changed()

## OUTLETS: the base level, in metres below the rim cell's INPUT ground. Water drains to it and the rim can
## erode down to it, no further. 0 lets water spill off at the rim's own level.
@export_range(0.0, 10.0, 0.05, "or_greater", "suffix:m") var outlet_level: float = 0.0:
	set(v):
		outlet_level = maxf(v, 0.0)
		_param_changed()

## MUSGRAVE: the original model -- each pass routes water one cell downhill, in grid steps, so the same
## world at another resolution erodes differently. PIPE: Mei et al. 2007's virtual-pipe shallow water, in
## metres and seconds, which converges as the resolution rises. Under PIPE each iteration simulates Time
## Step seconds, Erosion and Deposition Speed are per second, and Sediment Capacity is far smaller (try
## 0.05-0.5): it scales tilt x speed x depth rather than the Musgrave capacity term.
@export_enum("Musgrave", "Pipe") var model: int = 0:
	set(v):
		model = clampi(v, 0, 1)
		_param_changed()
		notify_property_list_changed()

## PIPE: seconds of simulated time per iteration. Substepped internally for stability, so a large value is
## safe, only slower.
@export_range(0.01, 5.0, 0.01, "or_greater", "suffix:s") var time_step: float = 0.5:
	set(v):
		time_step = maxf(v, 1e-3)
		_param_changed()


@export_group("Evaluation")

@export_tool_button("Bake Hydraulic Erosion") var _bake_btn = clear_cache


## Names this node's own Bake button, for the freeze warning.
func bake_label() -> String:
	return "Bake Hydraulic Erosion"


func op() -> StringName:
	return &"dev_erosion_hydraulic"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "[Dev/GD] Hydraulic Erosion"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 1


func input_names() -> PackedStringArray:
	return PackedStringArray(["height"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT])


func output_count() -> int:
	return 3


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "sediment", "flow"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.MASK])


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if p_inputs.size() > 0 \
			else Pasture3DGraphOps.zeros(n)
	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	return solve_cached(_surface_hash(surface, p_gw, p_gh), func(): return _solve_gdscript(surface, p_gw, p_gh, p_rect))


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func _validate_property(p_property: Dictionary) -> void:
	if p_property.name == "time_step" and model != 1:
		p_property.usage = PROPERTY_USAGE_NO_EDITOR


func _param_changed() -> void:
	mark_dirty_since_bake()
	emit_changed()


func _surface_hash(p_surface: PackedFloat32Array, p_gw: int, p_gh: int) -> int:
	return solver_cache_key(p_gw, p_gh, [p_surface])


func _solve_gdscript(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2) -> Array:
	var params := {
		"iterations": iterations,
		"rain_rate": rain_rate,
		"evaporation_rate": evaporation_rate,
		"sediment_capacity": sediment_capacity,
		"erosion_speed": erosion_speed,
		"deposition_speed": deposition_speed,
		"min_slope": min_slope,
		"edge_mode": edge_mode,
		"outlet_level": outlet_level,
		"model": model,
		"time_step": time_step,
	}
	return solve_oracle(p_surface, p_gw, p_gh, p_rect, params)


static func solve_oracle(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_params: Dictionary) -> Array:
	if clampi(int(p_params.get("model", 0)), 0, 1) == 1:
		return _pipe_oracle(p_surface, p_gw, p_gh, p_rect, p_params)
	var n := p_gw * p_gh
	var height := p_surface.duplicate()
	var sediment := PackedFloat32Array(); sediment.resize(n); sediment.fill(0.0)
	var water := PackedFloat32Array(); water.resize(n); water.fill(0.0)
	var flow_accum := PackedFloat32Array(); flow_accum.resize(n); flow_accum.fill(0.0)

	var p_iterations: int = maxi(int(p_params.get("iterations", 25)), 1)
	var p_rain: float = maxf(float(p_params.get("rain_rate", 0.05)), 0.0)
	var p_evap: float = clampf(float(p_params.get("evaporation_rate", 0.02)), 0.0, 1.0)
	var p_cap: float = maxf(float(p_params.get("sediment_capacity", 8.0)), 0.0)
	var p_ero_spd: float = clampf(float(p_params.get("erosion_speed", 0.5)), 0.0, 1.0)
	var p_dep_spd: float = clampf(float(p_params.get("deposition_speed", 0.4)), 0.0, 1.0)
	var p_min_slope: float = maxf(float(p_params.get("min_slope", 0.01)), 0.0)
	var outlets: bool = clampi(int(p_params.get("edge_mode", 0)), 0, 1) == 1
	var p_outlet: float = maxf(float(p_params.get("outlet_level", 0.0)), 0.0)

	var dx: float = p_rect.size.x / float(maxi(p_gw, 1))
	var dz: float = p_rect.size.y / float(maxi(p_gh, 1))
	var cell_dist: float = sqrt(maxf(dx * dz, 1e-6))

	var n_dx: Array[int] = [-1, 1, 0, 0]
	var n_dz: Array[int] = [0, 0, -1, 1]
	var n_dist: Array[float] = [dx, dx, dz, dz]

	for _pass in range(p_iterations):
		for i in range(n):
			if is_finite(height[i]):
				water[i] += p_rain
				flow_accum[i] += p_rain

		var next_water := water.duplicate()
		# The routing sweep both scatters into and reads flow_accum, so it reads a SNAPSHOT -- see the note
		# on the native kernel's twin of this line. Reading the live array made carrying capacity depend on
		# raster order.
		var flow_accum_in := flow_accum.duplicate()
		var next_sediment := sediment.duplicate()
		var next_height := height.duplicate()

		for iz in range(p_gh):
			var row := iz * p_gw
			for ix in range(p_gw):
				var i := row + ix
				var h_c: float = height[i]
				var w_c: float = water[i]
				if not is_finite(h_c) or w_c <= 1e-7:
					continue

				var total_alt: float = h_c + w_c
				var diffs: Array[float] = [0.0, 0.0, 0.0, 0.0]
				var total_diff: float = 0.0
				var max_slope: float = 0.0
				var min_downhill_diff: float = INF

				for k in range(4):
					var nx: int = ix + n_dx[k]
					var nz: int = iz + n_dz[k]
					# The neighbour's water surface; an edge or no-data neighbour has one only under OUTLETS.
					var n_total: float = 0.0
					var has_surface: bool = false
					if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh and is_finite(height[nz * p_gw + nx]):
						var ni: int = nz * p_gw + nx
						n_total = height[ni] + water[ni]
						has_surface = true
					elif outlets:
						n_total = p_surface[i] - p_outlet
						has_surface = true
					if has_surface:
						var diff: float = total_alt - n_total
						if diff > 0.0:
							diffs[k] = diff
							total_diff += diff
							min_downhill_diff = minf(min_downhill_diff, diff)
							var slope: float = diff / n_dist[k]
							if slope > max_slope:
								max_slope = slope

				if total_diff > 0.0:
					var eff_slope: float = maxf(max_slope, p_min_slope)
					var vel: float = sqrt(clampf(eff_slope * cell_dist, 0.05, 50.0))
					var flow_factor: float = log(1.0 + flow_accum_in[i] * 10.0) + 1.0
					var cap: float = p_cap * eff_slope * vel * w_c * flow_factor * 0.5

					var sed_c: float = sediment[i]
					var max_erode: float = min_downhill_diff * 0.4
					var max_dep: float = min_downhill_diff * 0.4

					if sed_c < cap:
						var erode_amt: float = clampf((cap - sed_c) * p_ero_spd * 0.4, 0.0, max_erode)
						next_height[i] -= erode_amt
						sed_c += erode_amt
					elif sed_c > cap:
						var dep_amt: float = clampf((sed_c - cap) * p_dep_spd * 0.4, 0.0, max_dep)
						next_height[i] += dep_amt
						sed_c -= dep_amt

					var flow_out: float = minf(w_c * 0.6, total_diff * 0.5)
					next_water[i] -= flow_out

					for k in range(4):
						if diffs[k] > 0.0:
							var frac: float = diffs[k] / total_diff
							var moved_w: float = flow_out * frac
							var moved_s: float = sed_c * (moved_w / maxf(w_c, 1e-6))
							var tx: int = ix + n_dx[k]
							var tz: int = iz + n_dz[k]
							# An outlet off the grid has nobody to receive it: it leaves the domain.
							if tx >= 0 and tx < p_gw and tz >= 0 and tz < p_gh:
								var ni: int = tz * p_gw + tx
								next_water[ni] += moved_w
								next_sediment[ni] += moved_s
								flow_accum[ni] += moved_w
							sed_c = maxf(sed_c - moved_s, 0.0)

					# += the DELTA, not = the retained amount -- see the note on the native kernel's twin of
					# this line. next_sediment starts as a copy of sediment and neighbours scatter into it,
					# so assigning here discarded upstream deposits made earlier in the same scan.
					next_sediment[i] += sed_c - sediment[i]

		for i in range(n):
			if is_finite(next_height[i]):
				next_water[i] *= (1.0 - p_evap)

		water = next_water
		sediment = next_sediment
		height = next_height

	return _normalise(height, sediment, flow_accum)


static func _normalise(height: PackedFloat32Array, sediment: PackedFloat32Array, flow_accum: PackedFloat32Array) -> Array:
	var n := height.size()
	var max_flow: float = 1e-6
	var max_sed: float = 1e-6
	for i in range(n):
		if is_finite(height[i]):
			max_flow = maxf(max_flow, flow_accum[i])
			max_sed = maxf(max_sed, sediment[i])

	var norm_sediment := PackedFloat32Array(); norm_sediment.resize(n)
	var norm_flow := PackedFloat32Array(); norm_flow.resize(n)
	for i in range(n):
		if is_finite(height[i]):
			norm_sediment[i] = clampf(sediment[i] / max_sed, 0.0, 1.0)
			norm_flow[i] = clampf(flow_accum[i] / max_flow, 0.0, 1.0)
		else:
			norm_sediment[i] = 0.0
			norm_flow[i] = 0.0

	return [height, norm_sediment, norm_flow]



## PIPE: Mei, Decaudin & Hu 2007's virtual-pipe model -- the twin of pipe_solve in
## pasture_3d_erosion_hydraulic.cpp, operation for operation, so the two agree to the bit. Every grid is
## float32 and every temporary a double, exactly as there.
static func _pipe_oracle(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_params: Dictionary) -> Array:
	const PIPE_G := 9.81
	const PIPE_DEPTH := 1.0
	const PIPE_MIN_DEPTH := 1e-4
	var n := p_gw * p_gh
	var height := p_surface.duplicate()
	var sediment := PackedFloat32Array(); sediment.resize(n); sediment.fill(0.0)
	var flow := PackedFloat32Array(); flow.resize(n); flow.fill(0.0)
	var water := PackedFloat32Array(); water.resize(n); water.fill(0.0)
	var flux: Array[PackedFloat32Array] = []
	for k in 4:
		var f := PackedFloat32Array(); f.resize(n); f.fill(0.0)
		flux.append(f)
	var vel_x := PackedFloat32Array(); vel_x.resize(n); vel_x.fill(0.0)
	var vel_z := PackedFloat32Array(); vel_z.resize(n); vel_z.fill(0.0)
	var sed_mid := PackedFloat32Array(); sed_mid.resize(n); sed_mid.fill(0.0)
	var next_height := PackedFloat32Array(); next_height.resize(n)
	var next_water := PackedFloat32Array(); next_water.resize(n)

	var p_iterations: int = maxi(int(p_params.get("iterations", 25)), 1)
	var p_rain: float = maxf(float(p_params.get("rain_rate", 0.05)), 0.0)
	var p_evap: float = clampf(float(p_params.get("evaporation_rate", 0.02)), 0.0, 1.0)
	var p_cap: float = maxf(float(p_params.get("sediment_capacity", 8.0)), 0.0)
	var p_ero_spd: float = clampf(float(p_params.get("erosion_speed", 0.5)), 0.0, 1.0)
	var p_dep_spd: float = clampf(float(p_params.get("deposition_speed", 0.4)), 0.0, 1.0)
	var p_min_slope: float = maxf(float(p_params.get("min_slope", 0.01)), 0.0)
	var outlets: bool = clampi(int(p_params.get("edge_mode", 0)), 0, 1) == 1
	var p_outlet: float = maxf(float(p_params.get("outlet_level", 0.0)), 0.0)
	var p_time_step: float = maxf(float(p_params.get("time_step", 0.5)), 1e-3)

	var dx: float = p_rect.size.x / float(p_gw)
	var dz: float = p_rect.size.y / float(p_gh)
	var area: float = dx * dz
	var n_dx: Array[int] = [-1, 1, 0, 0]
	var n_dz: Array[int] = [0, 0, -1, 1]
	var pipe_len: Array[float] = [dx, dx, dz, dz]
	var side: Array[float] = [dz, dz, dx, dx]

	var dt_max: float = 0.25 * minf(dx, dz) / sqrt(PIPE_G * PIPE_DEPTH)
	var substeps: int = maxi(1, int(ceil(p_time_step / dt_max)))
	var dt: float = p_time_step / float(substeps)
	var k_ero: float = minf(1.0, p_ero_spd * dt)
	var k_dep: float = minf(1.0, p_dep_spd * dt)

	for pass_i in p_iterations:
		for i in n:
			if is_finite(height[i]):
				water[i] = water[i] + p_rain

		for sub in substeps:
			# A. flux
			for iz in p_gh:
				for ix in p_gw:
					var i := iz * p_gw + ix
					var b: float = height[i]
					if not is_finite(b):
						for k in 4:
							flux[k][i] = 0.0
						continue
					var surf: float = b + water[i]
					var f: Array[float] = [0.0, 0.0, 0.0, 0.0]
					var total := 0.0
					for k in 4:
						var nx: int = ix + n_dx[k]
						var nz: int = iz + n_dz[k]
						var n_surf: float
						if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh and is_finite(height[nz * p_gw + nx]):
							var ni := nz * p_gw + nx
							n_surf = height[ni] + water[ni]
						elif outlets:
							n_surf = p_surface[i] - p_outlet
						else:
							f[k] = 0.0
							continue
						f[k] = maxf(0.0, flux[k][i] + dt * PIPE_G * side[k] * PIPE_DEPTH * (surf - n_surf) / pipe_len[k])
						total += f[k]
					var volume: float = water[i] * area
					if total * dt > volume and total > 0.0:
						var scale: float = volume / (total * dt)
						for k in 4:
							f[k] = f[k] * scale
					for k in 4:
						flux[k][i] = f[k]

			# B. water, velocity, erosion and deposition
			for iz in p_gh:
				for ix in p_gw:
					var i := iz * p_gw + ix
					var b: float = height[i]
					if not is_finite(b):
						next_height[i] = height[i]
						next_water[i] = water[i]
						sed_mid[i] = sediment[i]
						vel_x[i] = 0.0
						vel_z[i] = 0.0
						continue
					var inn: Array[float] = [0.0, 0.0, 0.0, 0.0]
					var b_n: Array[float] = [b, b, b, b]
					for k in 4:
						var nx: int = ix + n_dx[k]
						var nz: int = iz + n_dz[k]
						if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh and is_finite(height[nz * p_gw + nx]):
							var ni := nz * p_gw + nx
							inn[k] = flux[k ^ 1][ni]
							b_n[k] = height[ni]
					var o0: float = flux[0][i]
					var o1: float = flux[1][i]
					var o2: float = flux[2][i]
					var o3: float = flux[3][i]
					var w0: float = water[i]
					var net: float = (inn[0] + inn[1] + inn[2] + inn[3]) - (o0 + o1 + o2 + o3)
					var w1: float = maxf(0.0, w0 + dt * net / area)
					var depth: float = 0.5 * (w0 + w1)
					var u := 0.0
					var v := 0.0
					if depth > PIPE_MIN_DEPTH:
						u = 0.5 * (inn[0] - o0 + o1 - inn[1]) / (dz * depth)
						v = 0.5 * (inn[2] - o2 + o3 - inn[3]) / (dx * depth)
					var gx: float = (b_n[1] - b_n[0]) / (2.0 * dx)
					var gz: float = (b_n[3] - b_n[2]) / (2.0 * dz)
					var grad2: float = gx * gx + gz * gz
					var tilt: float = maxf(sqrt(grad2 / (1.0 + grad2)), p_min_slope)
					var speed: float = sqrt(u * u + v * v)
					var cap: float = p_cap * tilt * speed * w1
					var s: float = sediment[i]
					var b1: float = b
					if cap > s:
						var amt: float = k_ero * (cap - s)
						b1 = b - amt
						s = s + amt
					else:
						var amt: float = k_dep * (s - cap)
						b1 = b + amt
						s = s - amt
					next_height[i] = b1
					next_water[i] = w1
					sed_mid[i] = s
					vel_x[i] = u
					vel_z[i] = v
					flow[i] = flow[i] + speed * w1 * dt
			var th := height
			height = next_height
			next_height = th
			var tw := water
			water = next_water
			next_water = tw

			# C. carry
			for iz in p_gh:
				for ix in p_gw:
					var i := iz * p_gw + ix
					if not is_finite(height[i]):
						sediment[i] = sed_mid[i]
						continue
					var x: float = clampf(float(ix) - vel_x[i] * dt / dx, 0.0, float(p_gw - 1))
					var z: float = clampf(float(iz) - vel_z[i] * dt / dz, 0.0, float(p_gh - 1))
					var x0: int = int(floor(x))
					var z0: int = int(floor(z))
					var x1: int = mini(x0 + 1, p_gw - 1)
					var z1: int = mini(z0 + 1, p_gh - 1)
					var t00 := z0 * p_gw + x0
					var t10 := z0 * p_gw + x1
					var t01 := z1 * p_gw + x0
					var t11 := z1 * p_gw + x1
					if not (is_finite(height[t00]) and is_finite(height[t10]) and is_finite(height[t01]) and is_finite(height[t11])):
						sediment[i] = sed_mid[i]
						continue
					var fx: float = x - float(x0)
					var fz: float = z - float(z0)
					var top: float = sed_mid[t00] * (1.0 - fx) + sed_mid[t10] * fx
					var bot: float = sed_mid[t01] * (1.0 - fx) + sed_mid[t11] * fx
					sediment[i] = top * (1.0 - fz) + bot * fz

		for i in n:
			if is_finite(height[i]):
				water[i] = water[i] * (1.0 - p_evap)

	return _normalise(height, sediment, flow)
