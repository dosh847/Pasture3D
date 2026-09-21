# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevHydraulicStreamLog — pure GDScript reference oracle for logarithmic stream-power erosion.
# Solves catchment drainage accumulation and logarithmic bedrock incision: E = K * log(1 + A^m * S^n).
# Used for algorithm prototyping, A/B testing, and automated headless CI parity verification.
@tool
class_name Pasture3DGraphNodeDevHydraulicStreamLog
extends Pasture3DGraphSolverNode


@export_group("Simulation")
## Number of simulation passes.
@export_range(1, 50, 1, "or_greater") var iterations: int = 15:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

## Bedrock channel incision intensity factor.
@export_range(0.01, 2.0, 0.01, "or_greater") var incision_rate: float = 0.15:
	set(v):
		incision_rate = maxf(v, 0.0)
		_param_changed()

## Catchment drainage area power exponent (m ≈ 0.5 in standard stream power law).
@export_range(0.1, 1.5, 0.05) var area_exponent: float = 0.5:
	set(v):
		area_exponent = maxf(v, 0.0)
		_param_changed()

## Local slope gradient power exponent (n ≈ 1.0 in standard stream power law).
@export_range(0.1, 2.0, 0.05) var slope_exponent: float = 1.0:
	set(v):
		slope_exponent = maxf(v, 0.0)
		_param_changed()

## Minimum upstream catchment accumulation required before channel carving begins.
@export_range(0.1, 50.0, 0.5) var min_catchment: float = 1.0:
	set(v):
		min_catchment = maxf(v, 0.0)
		_param_changed()

## Transverse channel diffusion / smoothing rate to avoid single-pixel crevasse artifacts.
@export_range(0.0, 0.5, 0.01) var bank_smoothing: float = 0.1:
	set(v):
		bank_smoothing = clampf(v, 0.0, 0.5)
		_param_changed()

## Relative elevation peak preservation factor [0.0..1.0] (Hesiod peak protection).
@export_range(0.0, 1.0, 0.05) var peak_preservation: float = 0.5:
	set(v):
		peak_preservation = clampf(v, 0.0, 1.0)
		_param_changed()

## Slope gradient shaping power exponent [0.1..2.0].
@export_range(0.1, 2.0, 0.05) var gradient_power: float = 0.8:
	set(v):
		gradient_power = clampf(v, 0.1, 2.0)
		_param_changed()

## Fill interior depressions on the ROUTING surface before flow accumulates, so drainage crosses basins
## instead of dying in them. Off reproduces the pre-fill behaviour, where every pit is a sink.
@export var fill_depressions: bool = true:
	set(v):
		fill_depressions = v
		_param_changed()

@export_group("Evaluation")

@export_tool_button("Bake Stream-Log Erosion") var _bake_btn = clear_cache


## Names this node's own Bake button, for the freeze warning.
func bake_label() -> String:
	return "Bake Stream-Log Erosion"


func op() -> StringName:
	return &"dev_hydraulic_stream_log"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "[Dev/GD] Logarithmic Stream Erosion"


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
	return PackedStringArray(["height", "channel_mask", "flow_accumulation", "erosion_depth"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.FIELD, PortType.FIELD])


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
		"iterations": iterations,
		"incision_rate": incision_rate,
		"area_exponent": area_exponent,
		"slope_exponent": slope_exponent,
		"min_catchment": min_catchment,
		"bank_smoothing": bank_smoothing,
		"peak_preservation": peak_preservation,
		"gradient_power": gradient_power,
		"fill_depressions": fill_depressions,
		"mask": p_mask,
	}


func _param_changed() -> void:
	mark_dirty_since_bake()
	emit_changed()


## Pure GDScript reference oracle for logarithmic stream power erosion.
static func solve_oracle(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_params: Dictionary) -> Array:
	if p_gw < 2 or p_gh < 2 or p_surface.size() != p_gw * p_gh:
		return [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]

	var n: int = p_gw * p_gh
	var height := p_surface.duplicate()
	var channel_mask := PackedFloat32Array()
	var flow_accum := PackedFloat32Array()
	var erosion_depth := PackedFloat32Array()
	channel_mask.resize(n)
	channel_mask.fill(0.0)
	flow_accum.resize(n)
	flow_accum.fill(0.0)
	erosion_depth.resize(n)
	erosion_depth.fill(0.0)

	var iterations: int = maxi(1, int(p_params.get("iterations", 15)))
	var incision_rate: float = maxf(0.0, float(p_params.get("incision_rate", 0.15)))
	var area_exponent: float = maxf(0.0, float(p_params.get("area_exponent", 0.5)))
	var slope_exponent: float = maxf(0.0, float(p_params.get("slope_exponent", 1.0)))
	var min_catchment: float = maxf(0.0, float(p_params.get("min_catchment", 1.0)))
	var bank_smoothing: float = clampf(float(p_params.get("bank_smoothing", 0.1)), 0.0, 0.5)
	var peak_preservation: float = clampf(float(p_params.get("peak_preservation", 0.5)), 0.0, 1.0)
	var gradient_power: float = clampf(float(p_params.get("gradient_power", 0.8)), 0.1, 2.0)
	var fill_depressions: bool = bool(p_params.get("fill_depressions", true))

	var mask: PackedFloat32Array = p_params.get("mask", PackedFloat32Array())
	var has_mask: bool = (mask.size() == n)

	var dx: float = p_rect.size.x / float(maxi(p_gw, 1))
	var dz: float = p_rect.size.y / float(maxi(p_gh, 1))

	var n_dx: Array[int] = [-1, 1, 0, 0, -1, 1, -1, 1]
	var n_dz: Array[int] = [0, 0, -1, 1, -1, -1, 1, 1]
	var n_dist: Array[float] = [dx, dx, dz, dz, sqrt(dx*dx + dz*dz), sqrt(dx*dx + dz*dz), sqrt(dx*dx + dz*dz), sqrt(dx*dx + dz*dz)]

	for pass_idx in range(iterations):
		# 1. Sort indices descending by elevation for DAG accumulation
		var order: Array[int] = []
		order.resize(n)
		for i in range(n):
			order[i] = i

		order.sort_custom(func(a: int, b: int) -> bool:
			var ha: float = height[a]
			var hb: float = height[b]
			if not is_finite(ha):
				return false
			if not is_finite(hb):
				return true
			return ha > hb
		)

		# 1b. Depression-filled ROUTING surface. Flow accumulation reads this; every other stage still
		# reads `height`, so filling changes which way water goes without lifting the terrain. Without it a
		# cell whose eight neighbours are all higher has sum_drop == 0 and absorbs its whole upstream
		# catchment, so the drainage network breaks at every pit instead of reaching the border the way
		# Hesiod's stream-power nodes do.
		var route: PackedFloat32Array = _fill_depressions(height, p_gw, p_gh, maxf(dx, dz)) if fill_depressions else height

		# 2. Accumulate drainage flow using MD8 multi-direction routing
		var current_flow := PackedFloat32Array()
		current_flow.resize(n)
		current_flow.fill(1.0)

		for idx in order:
			var h_c: float = route[idx]
			if not is_finite(h_c):
				continue
			var cx: int = idx % p_gw
			var cz: int = idx / p_gw

			var sum_drop: float = 0.0
			var drops: Array[float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]

			for k in range(8):
				var nx: int = cx + n_dx[k]
				var nz: int = cz + n_dz[k]
				if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh:
					var n_idx: int = nz * p_gw + nx
					var h_n: float = route[n_idx]
					if is_finite(h_n) and h_n < h_c:
						var drop: float = (h_c - h_n) / n_dist[k]
						var weighted_drop: float = pow(drop, 1.3)
						drops[k] = weighted_drop
						sum_drop += weighted_drop

			if sum_drop > 1.0e-6:
				var my_flow: float = current_flow[idx]
				for k in range(8):
					if drops[k] > 0.0:
						var nx: int = cx + n_dx[k]
						var nz: int = cz + n_dz[k]
						var n_idx: int = nz * p_gw + nx
						var frac: float = drops[k] / sum_drop
						current_flow[n_idx] += my_flow * frac

		# 3. Compute Logarithmic Stream-Power Incision with lateral bank spreading & Hesiod peak preservation
		var incision_map := PackedFloat32Array()
		incision_map.resize(n)
		incision_map.fill(0.0)

		for iz in range(p_gh):
			var row: int = iz * p_gw
			for ix in range(p_gw):
				var idx: int = row + ix
				# Discharge is a hydrological fact about the cell, not a product of the erosion it was
				# allowed to do, so it is published before the finite and mask early-outs reject the cell.
				flow_accum[idx] = current_flow[idx]

				var h_c: float = height[idx]
				if not is_finite(h_c):
					continue

				var m_val: float = mask[idx] if has_mask else 1.0
				if m_val <= 0.001:
					continue

				# Local slope gradient
				var h_l: float = height[row + ix - 1] if ix > 0 and is_finite(height[row + ix - 1]) else h_c
				var h_r: float = height[row + ix + 1] if ix < p_gw - 1 and is_finite(height[row + ix + 1]) else h_c
				var h_u: float = height[(iz - 1) * p_gw + ix] if iz > 0 and is_finite(height[(iz - 1) * p_gw + ix]) else h_c
				var h_d: float = height[(iz + 1) * p_gw + ix] if iz < p_gh - 1 and is_finite(height[(iz + 1) * p_gw + ix]) else h_c

				var gx: float = (h_r - h_l) / (2.0 * dx)
				var gz: float = (h_d - h_u) / (2.0 * dz)
				var slope: float = sqrt(gx * gx + gz * gz)

				var shaped_slope: float = pow(slope, gradient_power) if (gradient_power != 1.0) else slope

				var peak_weight: float = 1.0
				if peak_preservation > 0.0:
					var min_local: float = h_c
					var max_local: float = h_c
					for rz in range(maxi(0, iz - 2), mini(p_gh - 1, iz + 2) + 1):
						for rx in range(maxi(0, ix - 2), mini(p_gw - 1, ix + 2) + 1):
							var val: float = height[rz * p_gw + rx]
							if is_finite(val):
								if val < min_local: min_local = val
								if val > max_local: max_local = val
					var range_val: float = max_local - min_local
					if range_val > 1.0e-4:
						var re: float = (h_c - min_local) / range_val
						var s_re: float = re * re * (3.0 - 2.0 * re)
						peak_weight = (1.0 - peak_preservation) + peak_preservation * (1.0 - s_re)

				var diff: float = current_flow[idx] - min_catchment
				var a_accum: float = diff if (diff > 15.0) else (log(1.0 + exp(diff)) if diff > -15.0 else 0.0)

				if a_accum > 0.01 and slope > 1.0e-5:
					var power: float = pow(a_accum, area_exponent) * pow(shaped_slope, slope_exponent)
					var incision: float = incision_rate * log(1.0 + power) * peak_weight * m_val

					var center_weight: float = 1.0 - bank_smoothing * 0.6
					var neighbor_weight: float = (bank_smoothing * 0.6) * 0.25

					incision_map[idx] += incision * center_weight
					if ix > 0: incision_map[row + ix - 1] += incision * neighbor_weight
					if ix < p_gw - 1: incision_map[row + ix + 1] += incision * neighbor_weight
					if iz > 0: incision_map[(iz - 1) * p_gw + ix] += incision * neighbor_weight
					if iz < p_gh - 1: incision_map[(iz + 1) * p_gw + ix] += incision * neighbor_weight

		# 4. Apply incision with base-level descent clamping
		var next_height := height.duplicate()
		for iz in range(p_gh):
			var row: int = iz * p_gw
			for ix in range(p_gw):
				var idx: int = row + ix
				var h_c: float = height[idx]
				if not is_finite(h_c):
					continue

				var cut: float = incision_map[idx]
				if cut > 0.0:
					var cx: int = ix
					var cz: int = iz
					var min_downhill: float = h_c
					for k in range(8):
						var nx: int = cx + n_dx[k]
						var nz: int = cz + n_dz[k]
						if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh:
							var h_n: float = height[nz * p_gw + nx]
							if is_finite(h_n) and h_n < min_downhill:
								min_downhill = h_n

					var max_cut: float = maxf(0.0, (h_c - min_downhill) + 0.05 * cut)
					cut = minf(cut, max_cut)
					next_height[idx] = h_c - cut
					# Metres of rock removed, summed over passes. channel_mask below is the same cut divided
					# by a PARAMETER and clamped, so it saturates and cannot be converted back to a depth.
					erosion_depth[idx] += cut
					channel_mask[idx] = maxf(channel_mask[idx], clampf(cut / (incision_rate * 2.0 + 1.0e-5), 0.0, 1.0))

		height = next_height

	return [height, channel_mask, flow_accum, erosion_depth]


## Priority-Flood + epsilon depression filling, returning a ROUTING surface: every finite cell gets a
## strictly descending path to a drain, so MD8 accumulation never stalls in a pit.
##
## The order cells are popped in is a STRICT TOTAL order — (level ascending, then cell index ascending) —
## which is what makes this reproducible in the native twin. A heap keyed on level alone leaves ties to the
## heap's internal layout, and the two implementations would then disagree on plateaus.
##
## `p_eps` lifts each filled cell above the one that flooded it. It has to be large enough that the lift
## survives stage 2's `sum_drop > 1e-6` cutoff after drop^1.3 — hence a fraction of the CELL SIZE rather
## than an absolute metre value, so it holds at every terrain scale. The lift lands only on this surface;
## nothing downstream of here reads it.
static func _fill_depressions(p_height: PackedFloat32Array, p_gw: int, p_gh: int, p_cell: float) -> PackedFloat32Array:
	var n: int = p_gw * p_gh
	var filled := p_height.duplicate()
	var eps: float = 1.0e-3 * p_cell

	var closed := PackedByteArray()
	closed.resize(n)
	closed.fill(0)

	# Heap of (level, idx), parallel arrays. Plain `Array`, not Packed — the push/pop helpers mutate these
	# in place, and a Packed array is a VALUE type in GDScript, so they would only ever reorder a copy.
	# Levels always come from `filled`, a PackedFloat32Array, so every level pushed is already rounded to
	# float32 and the native twin rounds at the same point.
	var h_lvl: Array[float] = []
	var h_idx: Array[int] = []

	# Seeds: the border, plus any finite cell touching a non-finite one. Stage 2 treats a non-finite cell as
	# absorbing, so it is a drain here too — otherwise a basin walled in by NaN would never be reached.
	for i in range(n):
		var hv: float = p_height[i]
		if not is_finite(hv):
			continue
		var ix: int = i % p_gw
		var iz: int = i / p_gw
		var is_seed: bool = (ix == 0 or iz == 0 or ix == p_gw - 1 or iz == p_gh - 1)
		if not is_seed:
			for k in range(8):
				var nx: int = ix + _FILL_DX[k]
				var nz: int = iz + _FILL_DZ[k]
				if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh:
					if not is_finite(p_height[nz * p_gw + nx]):
						is_seed = true
						break
		if is_seed:
			closed[i] = 1
			_heap_push(h_lvl, h_idx, filled[i], i)

	while h_idx.size() > 0:
		var lvl: float = h_lvl[0]
		var idx: int = h_idx[0]
		_heap_pop(h_lvl, h_idx)
		var cx: int = idx % p_gw
		var cz: int = idx / p_gw
		for k in range(8):
			var nx: int = cx + _FILL_DX[k]
			var nz: int = cz + _FILL_DZ[k]
			if nx < 0 or nx >= p_gw or nz < 0 or nz >= p_gh:
				continue
			var n_idx: int = nz * p_gw + nx
			if closed[n_idx] != 0:
				continue
			if not is_finite(p_height[n_idx]):
				continue
			closed[n_idx] = 1
			filled[n_idx] = maxf(p_height[n_idx], lvl + eps)
			_heap_push(h_lvl, h_idx, filled[n_idx], n_idx)

	return filled


const _FILL_DX: Array[int] = [-1, 1, 0, 0, -1, 1, -1, 1]
const _FILL_DZ: Array[int] = [0, 0, -1, 1, -1, -1, 1, 1]


## True when (a_lvl, a_idx) orders before (b_lvl, b_idx). The index tie-break is what makes the fill order
## unique; see _fill_depressions.
static func _heap_less(p_a_lvl: float, p_a_idx: int, p_b_lvl: float, p_b_idx: int) -> bool:
	if p_a_lvl != p_b_lvl:
		return p_a_lvl < p_b_lvl
	return p_a_idx < p_b_idx


static func _heap_push(p_lvl: Array[float], p_idx: Array[int], p_level: float, p_cell: int) -> void:
	p_lvl.push_back(p_level)
	p_idx.push_back(p_cell)
	var i: int = p_idx.size() - 1
	while i > 0:
		var parent: int = (i - 1) / 2
		if not _heap_less(p_lvl[i], p_idx[i], p_lvl[parent], p_idx[parent]):
			break
		var tl: float = p_lvl[i]
		var ti: int = p_idx[i]
		p_lvl[i] = p_lvl[parent]
		p_idx[i] = p_idx[parent]
		p_lvl[parent] = tl
		p_idx[parent] = ti
		i = parent


static func _heap_pop(p_lvl: Array[float], p_idx: Array[int]) -> void:
	var last: int = p_idx.size() - 1
	p_lvl[0] = p_lvl[last]
	p_idx[0] = p_idx[last]
	p_lvl.resize(last)
	p_idx.resize(last)
	var size: int = p_idx.size()
	var i: int = 0
	while true:
		var l: int = 2 * i + 1
		var r: int = l + 1
		var best: int = i
		if l < size and _heap_less(p_lvl[l], p_idx[l], p_lvl[best], p_idx[best]):
			best = l
		if r < size and _heap_less(p_lvl[r], p_idx[r], p_lvl[best], p_idx[best]):
			best = r
		if best == i:
			break
		var tl: float = p_lvl[i]
		var ti: int = p_idx[i]
		p_lvl[i] = p_lvl[best]
		p_idx[i] = p_idx[best]
		p_lvl[best] = tl
		p_idx[best] = ti
		i = best
