# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevHydraulicParticle — pure GDScript reference oracle for particle-based hydraulic erosion.
# A Lagrangian droplet simulation tracking momentum, velocity, sediment pickup, transport, and deposition.
# Nothing here is Eulerian: the droplets carry the state and the grid only records what they leave behind.
# Used for algorithm prototyping, A/B testing, and automated headless CI parity verification.
@tool
class_name Pasture3DGraphNodeDevHydraulicParticle
extends Pasture3DGraphSolverNode


## CELLS: every length is a grid cell (the original solver). METRIC: world metres, resolution-invariant.
enum { UNITS_CELLS = 0, UNITS_METRIC = 1 }

@export_group("Simulation")
## Total number of raindrops / particles simulated across the terrain footprint.
@export_range(1000, 200000, 1000, "or_greater") var droplet_count: int = 25000:
	set(v):
		droplet_count = maxi(v, 1)
		_param_changed()

## Maximum lifetime / steps a single droplet can travel before terminating.
@export_range(5, 100, 1) var max_lifetime: int = 30:
	set(v):
		max_lifetime = maxi(v, 1)
		_param_changed()

## Droplet momentum weight [0.0..1.0]. Higher inertia causes droplets to overshoot turns and follow valley lines.
@export_range(0.0, 1.0, 0.01) var inertia: float = 0.05:
	set(v):
		inertia = clampf(v, 0.0, 1.0)
		_param_changed()

## Multiplier for the amount of sediment water can carry per unit of velocity and slope.
@export_range(0.1, 20.0, 0.1, "or_greater") var sediment_capacity: float = 4.0:
	set(v):
		sediment_capacity = maxf(v, 0.0)
		_param_changed()

## Rate at which soil/bedrock dissolves into the water droplet when below sediment capacity [0.0..1.0].
@export_range(0.0, 1.0, 0.01) var erosion_speed: float = 0.3:
	set(v):
		erosion_speed = clampf(v, 0.0, 1.0)
		_param_changed()

## Rate at which excess sediment is deposited onto the terrain when above capacity [0.0..1.0].
@export_range(0.0, 1.0, 0.01) var deposition_speed: float = 0.3:
	set(v):
		deposition_speed = clampf(v, 0.0, 1.0)
		_param_changed()

## Fraction of water volume that evaporates per droplet step [0.0..1.0].
@export_range(0.0, 0.5, 0.005) var evaporation_rate: float = 0.01:
	set(v):
		evaporation_rate = clampf(v, 0.0, 1.0)
		_param_changed()

## Minimum slope gradient used for sediment capacity calculation.
@export_range(0.001, 0.2, 0.005) var min_slope: float = 0.01:
	set(v):
		min_slope = maxf(v, 0.0001)
		_param_changed()

## Gravitational acceleration constant scaling downhill speed.
@export_range(0.5, 20.0, 0.5) var gravity: float = 4.0:
	set(v):
		gravity = maxf(v, 0.1)
		_param_changed()

## Absolute floor on the cut, in metres below the **input** surface: no cell may finish more than
## `bedrock_gap` below where it started. **0 disables it**, which is the default.
##
## It defaults off because it does not scale. A fixed 2 m was 5% of a 40 m mound and 0.25% of an 800 m
## one, so on anything large it stopped being a safety rail and became the shape: measured at the old
## default, 49.8% of eroding cells on a 400 m world were pinned at the cap, 80.6% at 2 km and 92.1% at
## 8 km. A solver saturated against a constant is not eroding, and it reads as resolution-invariant
## because the constant, not the physics, is setting the depth. Set it per-brush against that brush's
## relief when you actually want a floor.
@export_range(0.0, 200.0, 0.5, "or_greater") var bedrock_gap: float = 0.0:
	set(v):
		bedrock_gap = maxf(v, 0.0)
		_param_changed()

## Ridge forcing cross-gradient strength to organize droplets into dendritic tributary trees.
@export_range(0.0, 2.0, 0.05) var ridge_forcing: float = 0.0:
	set(v):
		ridge_forcing = maxf(v, 0.0)
		_param_changed()

## Deterministic random seed for particle distribution.
## CELLS or METRIC -- see Pasture3DGraphNodeHydraulicParticle.units.
@export_enum("Cells", "Metric") var units: int = UNITS_CELLS:
	set(v):
		units = clampi(v, 0, 1)
		_param_changed()

## Erosion brush radius in metres; 0 = four bilinear corners.
@export_range(0.0, 20.0, 0.1, "or_greater", "suffix:m") var radius_m: float = 0.0:
	set(v):
		radius_m = maxf(v, 0.0)
		_param_changed()

## METRIC: step length in metres.
@export_range(0.1, 20.0, 0.1, "or_greater", "suffix:m") var step_length_m: float = 1.0:
	set(v):
		step_length_m = maxf(v, 0.01)
		_param_changed()

## METRIC: droplets per 100 m².
@export_range(0.1, 200.0, 0.1, "or_greater") var droplet_density: float = 40.0:
	set(v):
		droplet_density = maxf(v, 0.0)
		_param_changed()

@export var seed: int = 1337:
	set(v):
		seed = v
		_param_changed()

## A droplet that dies still carrying sediment -- out of lifetime, an edge ahead, or stuck in a pit --
## drops it where it stands instead of losing it, so the solve moves no mass off the terrain (except
## where the mask scales it down). Off by default: the original solver discarded it, and turning this on
## raises the ends of channels and the floors of pits.
@export var deposit_at_death: bool = false:
	set(v):
		deposit_at_death = v
		_param_changed()


@export_group("Evaluation")

@export_tool_button("Bake Particle Erosion") var _bake_btn = clear_cache


## Names this node's own Bake button, for the freeze warning.
func bake_label() -> String:
	return "Bake Particle Erosion"


func op() -> StringName:
	return &"dev_hydraulic_particle"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "[Dev/GD] Particle Hydraulic Erosion"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["height", "mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK])


func output_count() -> int:
	return 4


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "eroded", "deposited", "flow"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.FIELD, PortType.FIELD, PortType.FIELD])


## The oracle is what this node IS, so it has to be what this node RUNS. Without these two, the class
## inherits Pasture3DGraphNode.eval_grid, which hands the first input straight back — the FROZEN/LIVE
## toggle, the bake button and the cache would all be decoration over a node that never solves, and
## GraphSolverFreezeGate [E] names exactly that. Mirrors the production twin's shape.
func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) 			if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var mask_in: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) 			if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array) else PackedFloat32Array()
	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)
	return solve_cached(solver_cache_key(p_gw, p_gh, [surface, mask_in]),
			func(): return solve_oracle(surface, p_gw, p_gh, p_rect, _params_for_oracle(mask_in)))


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


## Every key the oracle reads, so a parameter edit reaches the solve. Keys are the oracle's own
## `p_params.get(...)` names; a typo here is a silently ignored slider.
func _params_for_oracle(p_mask: PackedFloat32Array) -> Dictionary:
	return {
		"droplet_count": droplet_count,
		"max_lifetime": max_lifetime,
		"inertia": inertia,
		"sediment_capacity": sediment_capacity,
		"erosion_speed": erosion_speed,
		"deposition_speed": deposition_speed,
		"evaporation_rate": evaporation_rate,
		"min_slope": min_slope,
		"gravity": gravity,
		"bedrock_gap": bedrock_gap,
		"ridge_forcing": ridge_forcing,
		"seed": self.seed,
		"units": units,
		"radius_m": radius_m,
		"deposit_at_death": deposit_at_death,
		"step_length_m": step_length_m,
		"droplet_density": droplet_density,
		"mask": p_mask,
	}


func _param_changed() -> void:
	mark_dirty_since_bake()
	emit_changed()


## Deterministic 32-bit LCG PRNG for exact parity between GDScript and C++.
static func _next_rand(p_state: int) -> Array:
	var next_state: int = (p_state * 1664525 + 1013904223) & 0xFFFFFFFF
	var rand_float: float = float(next_state) / 4294967296.0
	return [next_state, rand_float]


## Pure GDScript reference oracle for particle hydraulic erosion.
## Beyer's erosion brush: every finite cell within R metres of (p_px, p_pz), weighted by (R - distance) and
## normalised to 1, in raster order -- the native `disc_footprint`, walked the same way. Returns
## [indices, weights], or an empty Array when nothing carries weight.
static func _disc_footprint(p_height: PackedFloat32Array, p_gw: int, p_gh: int, p_px: float, p_pz: float,
		p_dx: float, p_dz: float, p_radius_m: float) -> Array:
	var rcx: float = p_radius_m / p_dx
	var rcz: float = p_radius_m / p_dz
	var x0: int = maxi(0, int(ceil(p_px - rcx)))
	var x1: int = mini(p_gw - 1, int(floor(p_px + rcx)))
	var z0: int = maxi(0, int(ceil(p_pz - rcz)))
	var z1: int = mini(p_gh - 1, int(floor(p_pz + rcz)))
	var idx := PackedInt32Array()
	var w := PackedFloat64Array()
	var total: float = 0.0
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			var i: int = z * p_gw + x
			if not is_finite(p_height[i]):
				continue
			var ox: float = (float(x) - p_px) * p_dx
			var oz: float = (float(z) - p_pz) * p_dz
			var wt: float = p_radius_m - sqrt(ox * ox + oz * oz)
			if wt > 0.0:
				idx.append(i)
				w.append(wt)
				total += wt
	if total <= 0.0:
		return []
	for k in w.size():
		w[k] = w[k] / total
	return [idx, w]


static func solve_oracle(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_params: Dictionary) -> Array:
	if p_gw < 2 or p_gh < 2 or p_surface.size() != p_gw * p_gh:
		return [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]

	var n: int = p_gw * p_gh
	var height := p_surface.duplicate()
	var flow := PackedFloat32Array()
	flow.resize(n)
	flow.fill(0.0)

	var max_lifetime: int = maxi(1, int(p_params.get("max_lifetime", 30)))
	var inertia: float = clampf(float(p_params.get("inertia", 0.05)), 0.0, 1.0)
	var sediment_capacity: float = maxf(0.0, float(p_params.get("sediment_capacity", 4.0)))
	var erosion_speed: float = clampf(float(p_params.get("erosion_speed", 0.3)), 0.0, 1.0)
	var deposition_speed: float = clampf(float(p_params.get("deposition_speed", 0.3)), 0.0, 1.0)
	var evaporation_rate: float = clampf(float(p_params.get("evaporation_rate", 0.01)), 0.0, 1.0)
	var min_slope: float = maxf(0.0001, float(p_params.get("min_slope", 0.01)))
	var gravity: float = maxf(0.1, float(p_params.get("gravity", 4.0)))
	var bedrock_gap: float = maxf(0.0, float(p_params.get("bedrock_gap", 0.0)))
	var ridge_forcing: float = maxf(0.0, float(p_params.get("ridge_forcing", 0.0)))
	var rng_seed: int = int(p_params.get("seed", 1337))
	var metric: bool = clampi(int(p_params.get("units", UNITS_CELLS)), 0, 1) == UNITS_METRIC
	var radius_param: float = maxf(0.0, float(p_params.get("radius_m", 0.0)))
	var step_param: float = maxf(0.01, float(p_params.get("step_length_m", 1.0)))
	var density: float = maxf(0.0, float(p_params.get("droplet_density", 40.0)))

	# The native solver's constants, derived the same way -- see its comments.
	var cell_dx: float = maxf(p_rect.size.x / float(p_gw), 1e-9)
	var cell_dz: float = maxf(p_rect.size.y / float(p_gh), 1e-9)
	var step_m: float = step_param if metric else 1.0
	var step_cx: float = step_m / cell_dx if metric else 1.0
	var step_cz: float = step_m / cell_dz if metric else 1.0
	var scale: float = (step_m * step_m) / (cell_dx * cell_dz) if metric else 1.0
	var radius_m: float = maxf(radius_param, step_m) if metric else radius_param
	var disc_erode: bool = radius_m >= minf(cell_dx, cell_dz)
	var disc_deposit: bool = metric and disc_erode
	var droplet_count: int = maxi(1, int(p_params.get("droplet_count", 25000)))
	if metric:
		droplet_count = maxi(1, roundi(density * p_rect.size.x * p_rect.size.y / 100.0))
	var min_fall: float = min_slope * step_m if metric else min_slope

	var deposit_at_death: bool = bool(p_params.get("deposit_at_death", false))
	var mask: PackedFloat32Array = p_params.get("mask", PackedFloat32Array())
	var has_mask: bool = (mask.size() == n)

	# Low 32 bits, and a zero state is 1337 -- the native solver's rule, decided on the 32-bit value.
	var rng_state: int = rng_seed & 0xFFFFFFFF
	if rng_state == 0:
		rng_state = 1337

	for d in range(droplet_count):
		var r_res := _next_rand(rng_state)
		rng_state = r_res[0]
		var rx: float = r_res[1] * float(p_gw - 1)

		r_res = _next_rand(rng_state)
		rng_state = r_res[0]
		var rz: float = r_res[1] * float(p_gh - 1)

		var px: float = rx
		var pz: float = rz
		var dir_x: float = 0.0
		var dir_z: float = 0.0
		var speed: float = 1.0
		var water: float = 1.0
		var sed: float = 0.0

		# Which way this droplet's ridge forcing deflects. One shared sign sent every droplet the same way
		# across the slope; drawing it per droplet keeps the deflection and removes the drift. Skipped when
		# the forcing is off, so the default RNG stream is unchanged.
		var ridge_sign: float = 1.0
		if ridge_forcing > 0.0:
			r_res = _next_rand(rng_state)
			rng_state = r_res[0]
			if float(r_res[1]) < 0.5:
				ridge_sign = -1.0

		var init_ix: int = clampi(int(px), 0, p_gw - 1)
		var init_iz: int = clampi(int(pz), 0, p_gh - 1)
		var init_idx: int = init_iz * p_gw + init_ix
		if not is_finite(height[init_idx]):
			continue
		if has_mask and mask[init_idx] <= 0.001:
			continue

		for step in range(max_lifetime):
			var ix: int = int(floor(px))
			var iz: int = int(floor(pz))
			if ix < 0 or ix >= p_gw - 1 or iz < 0 or iz >= p_gh - 1:
				break

			var u: float = px - float(ix)
			var v: float = pz - float(iz)

			var i00: int = iz * p_gw + ix
			var i10: int = i00 + 1
			var i01: int = (iz + 1) * p_gw + ix
			var i11: int = i01 + 1

			var h00: float = height[i00]
			var h10: float = height[i10]
			var h01: float = height[i01]
			var h11: float = height[i11]

			if not is_finite(h00) or not is_finite(h10) or not is_finite(h01) or not is_finite(h11):
				break

			var h_curr: float = (1.0 - u) * (1.0 - v) * h00 + u * (1.0 - v) * h10 + (1.0 - u) * v * h01 + u * v * h11

			# Surface gradient
			var gx: float = (1.0 - v) * (h10 - h00) + v * (h11 - h01)
			var gz: float = (1.0 - u) * (h01 - h00) + u * (h11 - h10)
			if metric:
				gx /= cell_dx
				gz /= cell_dz

			# Cross-gradient deflection: pushes flow off the fall line so channels wander instead of
			# running straight down it. See ridge_sign above for why the direction is per droplet.
			if ridge_forcing > 0.0:
				var perp_x: float = -gz * ridge_forcing * 0.5 * ridge_sign
				var perp_z: float = gx * ridge_forcing * 0.5 * ridge_sign
				gx += perp_x
				gz += perp_z

			# Flow direction with inertia
			dir_x = dir_x * inertia - gx * (1.0 - inertia)
			dir_z = dir_z * inertia - gz * (1.0 - inertia)

			var dir_len: float = sqrt(dir_x * dir_x + dir_z * dir_z)
			if dir_len > 1.0e-6:
				dir_x /= dir_len
				dir_z /= dir_len
			else:
				r_res = _next_rand(rng_state)
				rng_state = r_res[0]
				var ang: float = r_res[1] * TAU
				dir_x = cos(ang)
				dir_z = sin(ang)

			var next_px: float = px + (dir_x * step_cx if metric else dir_x)
			var next_pz: float = pz + (dir_z * step_cz if metric else dir_z)

			var next_ix: int = int(floor(next_px))
			var next_iz: int = int(floor(next_pz))
			if next_ix < 0 or next_ix >= p_gw - 1 or next_iz < 0 or next_iz >= p_gh - 1:
				break

			var next_u: float = next_px - float(next_ix)
			var next_v: float = next_pz - float(next_iz)

			var ni00: int = next_iz * p_gw + next_ix
			var ni10: int = ni00 + 1
			var ni01: int = (next_iz + 1) * p_gw + next_ix
			var ni11: int = ni01 + 1

			var nh00: float = height[ni00]
			var nh10: float = height[ni10]
			var nh01: float = height[ni01]
			var nh11: float = height[ni11]

			if not is_finite(nh00) or not is_finite(nh10) or not is_finite(nh01) or not is_finite(nh11):
				break

			var h_next: float = (1.0 - next_u) * (1.0 - next_v) * nh00 + next_u * (1.0 - next_v) * nh10 + (1.0 - next_u) * next_v * nh01 + next_u * next_v * nh11
			var delta_h: float = h_next - h_curr

			# Bilinear weights for deposition/erosion on current cell quad
			var w00: float = (1.0 - u) * (1.0 - v)
			var w10: float = u * (1.0 - v)
			var w01: float = (1.0 - u) * v
			var w11: float = u * v

			var mask_val: float = 1.0
			if has_mask:
				mask_val = w00 * mask[i00] + w10 * mask[i10] + w01 * mask[i01] + w11 * mask[i11]

			var quad_i := PackedInt32Array([i00, i10, i01, i11])
			var quad_w := PackedFloat64Array([w00, w10, w01, w11])

			if delta_h > 0.0:
				# Moving uphill into pit — deposit sediment
				var deposit_amt: float = minf(sed, delta_h) * mask_val
				sed -= deposit_amt
				_lay(height, deposit_amt * scale, disc_deposit, quad_i, quad_w,
						p_gw, p_gh, px, pz, cell_dx, cell_dz, radius_m)
				break
			else:
				# Moving downhill — compute capacity and erode/deposit
				var slope: float = maxf(-delta_h, min_fall)
				var cap: float = slope * speed * water * sediment_capacity

				if sed > cap:
					var dep: float = (sed - cap) * deposition_speed * mask_val
					sed -= dep
					_lay(height, dep * scale, disc_deposit, quad_i, quad_w,
							p_gw, p_gh, px, pz, cell_dx, cell_dz, radius_m)
				else:
					# Erode bedrock with Hesiod Bedrock Floor protection
					var ero: float = minf((cap - sed) * erosion_speed, -delta_h) * mask_val

					if bedrock_gap > 0.0:
						# The tightest cell binds: cell i moves by `ero * scale * w_i`, so `ero` may not
						# exceed `room_i / (scale * w_i)` anywhere. See the native solver's twin of this
						# block for why CELLS' old weighted mean was not a bound.
						var fp: Array = []
						if disc_erode:
							fp = _disc_footprint(height, p_gw, p_gh, px, pz, cell_dx, cell_dz, radius_m)
						var fi: PackedInt32Array = fp[0] if not fp.is_empty() else quad_i
						var fw: PackedFloat64Array = fp[1] if not fp.is_empty() else quad_w
						var lim: float = INF
						for k in fi.size():
							if fw[k] > 0.0:
								var room: float = maxf(0.0, height[fi[k]] - (p_surface[fi[k]] - bedrock_gap))
								lim = minf(lim, room / (scale * fw[k]))
						ero = minf(ero, lim)

					sed += ero
					_lay(height, -ero * scale, disc_erode, quad_i, quad_w,
							p_gw, p_gh, px, pz, cell_dx, cell_dz, radius_m)

				speed = sqrt(maxf(0.0, speed * speed - delta_h * gravity))
				water *= (1.0 - evaporation_rate)

				# Flow accumulation
				flow[i00] += water * w00
				flow[i10] += water * w10
				flow[i01] += water * w01
				flow[i11] += water * w11

				px = next_px
				pz = next_pz

		# Death: whatever the droplet still carries lands where it last stood -- the native solver's twin.
		if deposit_at_death and sed > 0.0:
			var dix: int = int(floor(px))
			var diz: int = int(floor(pz))
			if dix >= 0 and dix < p_gw - 1 and diz >= 0 and diz < p_gh - 1:
				var di00: int = diz * p_gw + dix
				var di10: int = di00 + 1
				var di01: int = di00 + p_gw
				var di11: int = di01 + 1
				if is_finite(height[di00]) and is_finite(height[di10]) and is_finite(height[di01]) and is_finite(height[di11]):
					var du: float = px - float(dix)
					var dv: float = pz - float(diz)
					var dw00: float = (1.0 - du) * (1.0 - dv)
					var dw10: float = du * (1.0 - dv)
					var dw01: float = (1.0 - du) * dv
					var dw11: float = du * dv
					var dmask: float = 1.0
					if has_mask:
						dmask = dw00 * mask[di00] + dw10 * mask[di10] + dw01 * mask[di01] + dw11 * mask[di11]
					_lay(height, sed * dmask * scale, disc_deposit,
							PackedInt32Array([di00, di10, di01, di11]), PackedFloat64Array([dw00, dw10, dw01, dw11]),
							p_gw, p_gh, px, pz, cell_dx, cell_dz, radius_m)

	# Net change against the input, in metres, and flow as path length per area at unit droplet density.
	var eroded := PackedFloat32Array()
	var deposited := PackedFloat32Array()
	eroded.resize(n)
	deposited.resize(n)
	var step_len: float = step_m if metric else sqrt(cell_dx * cell_dz)
	var flow_scale: float = float(n) * step_len / float(maxi(droplet_count, 1))
	for i in range(n):
		var change: float = height[i] - p_surface[i]
		var ok: bool = is_finite(change)
		eroded[i] = maxf(0.0, -change) if ok else 0.0
		deposited[i] = maxf(0.0, change) if ok else 0.0
		flow[i] = flow[i] * flow_scale

	return [height, eroded, deposited, flow]


## Lay `p_a` (already times `scale`) on the height, over the disc when asked and it has weight, else over
## the bilinear quad.
static func _lay(r_height: PackedFloat32Array, p_a: float, p_disc: bool,
		p_qi: PackedInt32Array, p_qw: PackedFloat64Array, p_gw: int, p_gh: int, p_px: float,
		p_pz: float, p_dx: float, p_dz: float, p_radius_m: float) -> void:
	var fi := p_qi
	var fw := p_qw
	if p_disc:
		var fp := _disc_footprint(r_height, p_gw, p_gh, p_px, p_pz, p_dx, p_dz, p_radius_m)
		if not fp.is_empty():
			fi = fp[0]
			fw = fp[1]
	for k in fi.size():
		r_height[fi[k]] += p_a * fw[k]
