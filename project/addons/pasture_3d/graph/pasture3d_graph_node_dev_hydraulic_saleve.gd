# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevHydraulicSaleve — Pure GDScript Reference Oracle for Salève Hydraulic Erosion.
# Faithful 1-to-1 implementation of Hesiod / HighMap hmap::hydraulic_saleve steady-state chi-solver.

@tool
class_name Pasture3DGraphNodeDevHydraulicSaleve
extends Pasture3DGraphSolverNode


@export_group("Simulation")
@export_range(1, 1000, 1, "or_greater") var iterations: int = 200:
	set(v):
		iterations = maxi(v, 1)
		_param_changed()

@export_range(0.0, 0.01, 0.0001) var tolerance: float = 1.0e-3:
	set(v):
		tolerance = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var erosion_strength: float = 0.7:
	set(v):
		erosion_strength = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.01, 0.8, 0.01) var drainage_exponent: float = 0.15:
	set(v):
		drainage_exponent = clampf(v, 0.01, 0.8)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var drainage_noise: float = 0.15:
	set(v):
		drainage_noise = maxf(v, 0.0)
		_param_changed()

@export_range(0.05, 4.0, 0.05) var shape_preservation: float = 2.0:
	set(v):
		shape_preservation = clampf(v, 0.05, 4.0)
		_param_changed()

## Vertical scale (metres) every length is measured against; 0 = the input's own relief. Mirrors the
## native node's Reference Relief.
@export_range(0.0, 500.0, 1.0, "or_greater", "suffix:m") var reference_relief: float = 0.0:
	set(v):
		reference_relief = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 0.5, 0.01) var bank_smoothing: float = 0.0:
	set(v):
		bank_smoothing = clampf(v, 0.0, 0.5)
		_param_changed()

@export_range(0.0, 20.0, 0.1, "or_greater") var max_slope_center: float = 6.0:
	set(v):
		max_slope_center = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 20.0, 0.1, "or_greater") var max_slope_border: float = 0.0:
	set(v):
		max_slope_border = maxf(v, 0.0)
		_param_changed()

@export var uniform_slope: bool = false:
	set(v):
		uniform_slope = v
		_param_changed()

@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export_group("Sediment Deposition (Stage 2)")
## Alluvial hole-filling radius in METRES (mirrors the native node).
@export_range(0.0, 200.0, 0.5, "or_greater", "suffix:m") var deposition_radius: float = 25.0:
	set(v):
		deposition_radius = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var deposition_strength: float = 0.5:
	set(v):
		deposition_strength = clampf(v, 0.0, 1.0)
		_param_changed()

@export_group("Fine River Incision (Stage 3)")
@export_range(0.0, 1.0, 0.005) var stream_strength: float = 0.02:
	set(v):
		stream_strength = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.01, 1.0, 0.01) var stream_exp: float = 0.8:
	set(v):
		stream_exp = clampf(v, 0.01, 1.0)
		_param_changed()

@export_group("Post-Processing (Stage 4)")
@export var enable_post_smoothing: bool = false:
	set(v):
		enable_post_smoothing = v
		_param_changed()


@export_group("Evaluation")

@export_tool_button("Bake Salève Erosion") var _bake_btn = clear_cache


## Names this node's own Bake button, for the freeze warning.
func bake_label() -> String:
	return "Bake Salève Erosion"


func op() -> StringName:
	return &"dev_hydraulic_saleve"


func role() -> Role:
	return Role.SOLVER


func display_name() -> String:
	return "[Dev/GD] Salève Hydraulic Erosion"


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "dx", "dy", "mask"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		# SIGNED, not FLOAT. `dx`/`dy` are read as GRIDS — `p_inputs[1] as PackedFloat32Array` in
		# `eval_grid` below, handed straight to the solver as displacement fields — so declaring them
		# FLOAT described them as one value per port when they are one value per CELL. The consequence
		# was not cosmetic: a FLOAT port connects to nothing but another FLOAT, so these two could not be
		# wired at all, and being fields they have no inline property either. They were inert sockets.
		# SIGNED because a displacement is signed and zero is meaningful.
		PortType.SIGNED,
		PortType.SIGNED,
		PortType.MASK,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return 0.0
		2: return 0.0
		3: return 1.0
		_: return 0.0


func output_count() -> int:
	return 3


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "eroded_rock", "sediment"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.FIELD, PortType.FIELD])


func node_warnings() -> PackedStringArray:
	var w := super()
	return w


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var surface: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(n)
	var dx_in: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array) else PackedFloat32Array()
	var dy_in: PackedFloat32Array = (p_inputs[2] as PackedFloat32Array) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array) else PackedFloat32Array()
	var mask_in: PackedFloat32Array = (p_inputs[3] as PackedFloat32Array) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array) else PackedFloat32Array()

	if surface.size() != n:
		surface = Pasture3DGraphOps.zeros(n)

	var p := {
		"iterations": iterations,
		"erosion_strength": erosion_strength,
		"drainage_exponent": drainage_exponent,
		"drainage_noise": drainage_noise,
		"shape_preservation": shape_preservation,
		"reference_relief": reference_relief,
		"bank_smoothing": bank_smoothing,
		"seed": seed,
		"dx": dx_in,
		"dy": dy_in,
		"mask": mask_in,
		"deposition_radius": deposition_radius,
		"deposition_strength": deposition_strength,
		"stream_strength": stream_strength,
		"stream_exp": stream_exp,
		"enable_post_smoothing": enable_post_smoothing,
		"tolerance": tolerance,
		"max_slope_center": max_slope_center,
		"max_slope_border": max_slope_center if uniform_slope else max_slope_border,
	}

	# This node offered FROZEN, a Bake button and a stale flag over a cache that was never written:
	# the solve ran on every evaluation whatever the setting said, and `_param_changed` set `_stale`
	# on a freeze that did not exist. The freeze was UI. It is now the same one every other solver
	# uses.
	return solve_cached(solver_cache_key(p_gw, p_gh, [surface, dx_in, dy_in, mask_in]),
			func(): return solve_gd(surface, p_gw, p_gh, p_rect, p))


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


# ---- Pure GDScript Reference Oracle ----------------------------------------------------------------

static func _fast_hash_to_unit(p_seed: int, key: int) -> float:
	var n: int = (p_seed ^ (key * 0x5bd1e995)) & 0xffffffff
	n = (n ^ (n >> 13)) * 0x5bd1e995 & 0xffffffff
	n = (n ^ (n >> 15)) & 0xffffffff
	return float((n & 0x00ffffff)) / 8388608.0 - 1.0


# Mirrors the native saleve_value_noise.
static func _value_noise(p_x: float, p_z: float, p_seed: int) -> float:
	var fx: float = floor(p_x)
	var fz: float = floor(p_z)
	var ix: int = int(fx)
	var iz: int = int(fz)
	var c00: float = _fast_hash_to_unit(p_seed, _lattice_key(ix, iz))
	var c10: float = _fast_hash_to_unit(p_seed, _lattice_key(ix + 1, iz))
	var c01: float = _fast_hash_to_unit(p_seed, _lattice_key(ix, iz + 1))
	var c11: float = _fast_hash_to_unit(p_seed, _lattice_key(ix + 1, iz + 1))
	var tx: float = p_x - fx
	var tz: float = p_z - fz
	tx = tx * tx * (3.0 - 2.0 * tx)
	tz = tz * tz * (3.0 - 2.0 * tz)
	var a: float = c00 + (c10 - c00) * tx
	var b: float = c01 + (c11 - c01) * tx
	return a + (b - a) * tz


static func _lattice_key(p_x: int, p_z: int) -> int:
	return ((p_x * 73856093) & 0xffffffff) ^ ((p_z * 19349663) & 0xffffffff)


static func _edge_len(p_start: PackedInt32Array, p_nbr: PackedInt32Array, p_len: PackedFloat64Array, p_a: int, p_b: int) -> float:
	for e in range(p_start[p_a], p_start[p_a + 1]):
		if p_nbr[e] == p_b:
			return p_len[e]
	return 1.0e-5


# Children lists from the receivers, then a breadth-first walk out of every root in index order.
static func _build_tree(p_receivers: PackedInt32Array, p_n: int) -> Dictionary:
	var start := PackedInt32Array()
	start.resize(p_n + 1)
	for i in range(p_n):
		if p_receivers[i] != i:
			start[p_receivers[i] + 1] += 1
	for i in range(p_n):
		start[i + 1] += start[i]
	var fill := start.slice(0, p_n)
	var children := PackedInt32Array()
	children.resize(p_n)
	for i in range(p_n):
		var r: int = p_receivers[i]
		if r != i:
			children[fill[r]] = i
			fill[r] += 1
	var order := PackedInt32Array()
	var root_of := PackedInt32Array()
	root_of.resize(p_n)
	for i in range(p_n):
		if p_receivers[i] == i:
			order.append(i)
			root_of[i] = i
	var head: int = 0
	while head < order.size():
		var v: int = order[head]
		head += 1
		for c in range(start[v], start[v + 1]):
			var ch: int = children[c]
			root_of[ch] = root_of[v]
			order.append(ch)
	return {"order": order, "root_of": root_of}


static func _heap_less(p_k: Array, p_v: Array, p_a: int, p_b: int) -> bool:
	return p_k[p_a] < p_k[p_b] or (p_k[p_a] == p_k[p_b] and p_v[p_a] < p_v[p_b])


static func _heap_push(p_k: Array, p_v: Array, p_key: float, p_val: int) -> void:
	p_k.append(p_key)
	p_v.append(p_val)
	var i: int = p_k.size() - 1
	while i > 0:
		var parent: int = (i - 1) / 2
		if not _heap_less(p_k, p_v, i, parent):
			break
		_heap_swap(p_k, p_v, i, parent)
		i = parent


static func _heap_pop(p_k: Array, p_v: Array) -> void:
	var last: int = p_k.size() - 1
	p_k[0] = p_k[last]
	p_v[0] = p_v[last]
	p_k.resize(last)
	p_v.resize(last)
	var i: int = 0
	while true:
		var l: int = 2 * i + 1
		var r: int = l + 1
		var m: int = i
		if l < last and _heap_less(p_k, p_v, l, m):
			m = l
		if r < last and _heap_less(p_k, p_v, r, m):
			m = r
		if m == i:
			break
		_heap_swap(p_k, p_v, i, m)
		i = m


static func _heap_swap(p_k: Array, p_v: Array, p_a: int, p_b: int) -> void:
	var tk: float = p_k[p_a]
	p_k[p_a] = p_k[p_b]
	p_k[p_b] = tk
	var tv: int = p_v[p_a]
	p_v[p_a] = p_v[p_b]
	p_v[p_b] = tv


static func solve_gd(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_params: Dictionary) -> Array:
	var n: int = p_gw * p_gh
	if p_surface.size() != n or p_gw < 2 or p_gh < 2:
		var empty := PackedFloat32Array()
		empty.resize(n)
		empty.fill(0.0)
		return [p_surface.duplicate(), empty.duplicate(), empty]

	var mask: PackedFloat32Array = p_params.get("mask", PackedFloat32Array())
	var has_mask: bool = (mask.size() == n)
	var dx_arr: PackedFloat32Array = p_params.get("dx", PackedFloat32Array())
	var dy_arr: PackedFloat32Array = p_params.get("dy", PackedFloat32Array())
	var has_dx: bool = (dx_arr.size() == n)
	var has_dy: bool = (dy_arr.size() == n)

	var iters: int = maxi(1, int(p_params.get("iterations", 200)))
	var tolerance: float = maxf(0.0, float(p_params.get("tolerance", 1.0e-3)))
	var slope_center: float = maxf(0.0, float(p_params.get("max_slope_center", 6.0)))
	var slope_border: float = maxf(0.0, float(p_params.get("max_slope_border", 0.0)))
	var reroute: bool = bool(p_params.get("reroute_lakes", true))
	var stable_noise: bool = bool(p_params.get("stable_noise", true))
	var erosion_strength: float = clampf(float(p_params.get("erosion_strength", 0.7)), 0.0, 1.0)
	var m_exp: float = clampf(float(p_params.get("drainage_exponent", 0.15)), 0.01, 0.8)
	var noise_strength: float = maxf(0.0, float(p_params.get("drainage_noise", 0.15)))
	var shape_preservation: float = clampf(float(p_params.get("shape_preservation", 2.0)), 0.1, 4.0)
	var bank_smoothing: float = clampf(float(p_params.get("bank_smoothing", 0.0)), 0.0, 0.5)
	var p_seed: int = int(p_params.get("seed", 0))

	var reference_relief: float = maxf(0.0, float(p_params.get("reference_relief", 0.0)))
	var dep_radius: float = maxf(0.0, float(p_params.get("deposition_radius", 25.0)))
	var dep_strength: float = clampf(float(p_params.get("deposition_strength", 0.5)), 0.0, 1.0)
	var str_strength: float = clampf(float(p_params.get("stream_strength", 0.02)), 0.0, 1.0)
	var str_exp: float = clampf(float(p_params.get("stream_exp", 0.8)), 0.01, 1.0)
	var enable_post_smooth: bool = bool(p_params.get("enable_post_smoothing", false))

	var zmin: float = INF
	var zmax: float = -INF
	for v in p_surface:
		if is_finite(v):
			if v < zmin: zmin = v
			if v > zmax: zmax = v

	if zmax - zmin < 1.0e-5:
		var zeroes := PackedFloat32Array()
		zeroes.resize(n)
		zeroes.fill(0.0)
		return [p_surface.duplicate(), zeroes.duplicate(), zeroes]

	var zptp: float = zmax - zmin
	# The solver's unit of length: a vertical scale in metres that every horizontal distance is divided by,
	# so slopes are true gradients and the grid's cell COUNT enters nothing. 0 = take it from the input's
	# own relief (moves with the solved extent — a Modifier Margin brings surrounding ground into range).
	# Mirrors hydraulic_saleve_solve; the parity gate compares the two.
	var relief_ref: float = reference_relief if reference_relief > 0.0 else zptp
	var vref: float = maxf(relief_ref, 1.0e-5)
	var z := PackedFloat32Array()
	z.resize(n)
	var erodibility := PackedFloat32Array()
	erodibility.resize(n)
	var is_outlet: Array[bool] = []
	is_outlet.resize(n)

	for iz in range(p_gh):
		for ix in range(p_gw):
			var idx: int = iz * p_gw + ix
			var h: float = p_surface[idx]
			if not is_finite(h):
				z[idx] = 0.0
				is_outlet[idx] = true
				continue
			var zn: float = (h - zmin) / zptp
			z[idx] = zn
			erodibility[idx] = pow(clampf(1.0 - (h - zmin) / vref, 0.01, 1.0), shape_preservation)
			is_outlet[idx] = (ix == 0 or ix == p_gw - 1 or iz == 0 or iz == p_gh - 1)

	var cell_dx: float = (p_rect.size.x / float(maxi(p_gw, 1))) if p_rect.size.x > 0.0 else 1.0
	var cell_dz: float = (p_rect.size.y / float(maxi(p_gh, 1))) if p_rect.size.y > 0.0 else 1.0
	var dx: float = cell_dx / vref
	var dz: float = cell_dz / vref
	var diag_dist: float = sqrt(dx * dx + dz * dz)
	var cell_area: float = dx * dz
	var n_dx: Array[int] = [-1, 1, 0, 0, -1, 1, -1, 1]
	var n_dz: Array[int] = [0, 0, -1, 1, -1, -1, 1, 1]
	var n_dist: Array[float] = [dx, dx, dz, dz, diag_dist, diag_dist, diag_dist, diag_dist]

	# The drainage graph: neighbour lists and edge lengths (mirrors the native solver's adjacency).
	var nbr_start := PackedInt32Array()
	nbr_start.resize(n + 1)
	var nbr := PackedInt32Array()
	var nbr_len := PackedFloat64Array()
	var nbr_dir := PackedInt32Array()
	for idx in range(n):
		nbr_start[idx] = nbr.size()
		var ix: int = idx % p_gw
		var iz: int = idx / p_gw
		for k in range(8):
			var nx: int = ix + n_dx[k]
			var nz: int = iz + n_dz[k]
			if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh:
				nbr.append(nz * p_gw + nx)
				nbr_len.append(n_dist[k])
				nbr_dir.append(k)
	nbr_start[n] = nbr.size()

	# Break flats: 1e-3 of low-frequency value noise on a fixed 50 m world lattice.
	var fseed: int = (p_seed ^ 0x9e3779b9) & 0xffffffff
	for idx in range(n):
		if not is_finite(p_surface[idx]):
			continue
		var wx: float = p_rect.position.x + (float(idx % p_gw) + 0.5) * cell_dx
		var wz: float = p_rect.position.y + (float(idx / p_gw) + 0.5) * cell_dz
		z[idx] = z[idx] + 1.0e-3 * _value_noise(wx / 50.0, wz / 50.0, fseed)

	# Radial slope cap, converted to unit elevation per unit length.
	var slope_cap := PackedFloat32Array()
	slope_cap.resize(n)
	var cx: float = p_rect.position.x + 0.5 * cell_dx * p_gw
	var cz: float = p_rect.position.y + 0.5 * cell_dz * p_gh
	var side: float = maxf(minf(cell_dx * p_gw, cell_dz * p_gh), 1.0e-6)
	var to_unit: float = vref / zptp
	for idx in range(n):
		var wx: float = p_rect.position.x + (float(idx % p_gw) + 0.5) * cell_dx
		var wz: float = p_rect.position.y + (float(idx / p_gw) + 0.5) * cell_dz
		var r: float = sqrt((wx - cx) * (wx - cx) + (wz - cz) * (wz - cz)) / side
		var pulse: float = (1.0 - r * r * (3.0 - 2.0 * r)) if r < 1.0 else 0.0
		slope_cap[idx] = (slope_border + (slope_center - slope_border) * pulse) * to_unit

	var receivers := PackedInt32Array()
	receivers.resize(n)
	var area_acc := PackedFloat32Array()
	area_acc.resize(n)
	var response_times := PackedFloat32Array()
	response_times.resize(n)
	var tree := {}

	# Stage 1: Steady-State LEM solve
	var iters_done: int = 0
	for iter in range(iters):
		iters_done = iter + 1
		var pass_seed: int = p_seed if stable_noise else p_seed + iter * 17
		for idx in range(n):
			if is_outlet[idx]:
				receivers[idx] = idx
				continue
			var z_c: float = z[idx]
			var best_score: float = -1.0e9
			var best: int = idx
			for e in range(nbr_start[idx], nbr_start[idx + 1]):
				var n_idx: int = nbr[e]
				var dz_val: float = z_c - z[n_idx]
				if dz_val > 0.0:
					var slope: float = dz_val / nbr_len[e]
					var noise: float = _fast_hash_to_unit(pass_seed, idx ^ (n_idx << 16))
					var warp_factor: float = 1.0
					if has_dx or has_dy:
						var k: int = nbr_dir[e]
						var wdx: float = dx_arr[idx] if has_dx else 0.0
						var wdy: float = dy_arr[idx] if has_dy else 0.0
						warp_factor += 0.5 * (wdx * float(n_dx[k]) + wdy * float(n_dz[k]))
					var score: float = slope * (warp_factor + noise_strength * noise)
					if score > best_score:
						best_score = score
						best = n_idx
			receivers[idx] = best

		tree = _build_tree(receivers, n)
		var root_of: PackedInt32Array = tree.root_of

		# Lake rerouting: shortest-path search from the outlets; the first step into an undrained basin
		# reverses its receiver chain toward the vertex the search came from. Ties on (distance, index).
		var any_pit: bool = false
		var basin_drained := PackedByteArray()
		basin_drained.resize(n)
		for i in range(n):
			basin_drained[i] = 1 if is_outlet[i] else 0
			if receivers[i] == i and not is_outlet[i]:
				any_pit = true
		if any_pit and reroute:
			var settled := PackedByteArray()
			settled.resize(n)
			var dist := PackedFloat64Array()
			dist.resize(n)
			dist.fill(INF)
			var pred := PackedInt32Array()
			pred.resize(n)
			pred.fill(-1)
			var hk: Array = []
			var hv: Array = []
			for i in range(n):
				if is_outlet[i]:
					dist[i] = 0.0
					_heap_push(hk, hv, 0.0, i)
			while hv.size() > 0:
				var d0: float = hk[0]
				var c: int = hv[0]
				_heap_pop(hk, hv)
				if settled[c] == 1:
					continue
				settled[c] = 1
				if basin_drained[root_of[c]] == 0:
					var prev: int = pred[c]
					var cur: int = c
					while true:
						var nxt: int = receivers[cur]
						receivers[cur] = prev
						if nxt == cur:
							break
						prev = cur
						cur = nxt
					basin_drained[root_of[c]] = 1
				for e in range(nbr_start[c], nbr_start[c + 1]):
					var j: int = nbr[e]
					var nd: float = d0 + nbr_len[e]
					if settled[j] == 0 and nd < dist[j]:
						dist[j] = nd
						pred[j] = c
						_heap_push(hk, hv, nd, j)
			tree = _build_tree(receivers, n)
			root_of = tree.root_of

		var order: PackedInt32Array = tree.order
		area_acc.fill(cell_area)
		for k in range(n - 1, -1, -1):
			var idx: int = order[k]
			var r: int = receivers[idx]
			if r != idx:
				area_acc[r] += area_acc[idx]
		for k in range(n):
			var idx: int = order[k]
			var r: int = receivers[idx]
			if r == idx:
				response_times[idx] = 0.0
				continue
			var d: float = maxf(_edge_len(nbr_start, nbr, nbr_len, idx, r), 1.0e-5)
			var celerity: float = erodibility[idx] * pow(maxf(area_acc[idx], cell_area), m_exp)
			response_times[idx] = response_times[r] + (d / maxf(celerity, 1.0e-4))
		var diff: float = 0.0
		for k in range(n):
			var idx: int = order[k]
			var r: int = receivers[idx]
			if r == idx:
				continue
			var new_z: float = z[root_of[idx]] + response_times[idx]
			var d: float = maxf(_edge_len(nbr_start, nbr, nbr_len, idx, r), 1.0e-5)
			var cap: float = z[r] + slope_cap[idx] * d
			if new_z > cap:
				new_z = cap
			diff += absf(new_z - z[idx])
			z[idx] = new_z
		var zlo: float = INF
		var zhi: float = -INF
		for v in z:
			zlo = minf(zlo, v)
			zhi = maxf(zhi, v)
		if diff / float(n) < tolerance * maxf(zhi - zlo, 1.0e-5):
			break
	var order_final: PackedInt32Array = tree.order

	var ze_min: float = INF
	var ze_max: float = -INF
	for v in z:
		if v < ze_min: ze_min = v
		if v > ze_max: ze_max = v
	var ze_span: float = maxf(ze_max - ze_min, 1.0e-5)
	for i in range(n):
		z[i] = (z[i] - ze_min) / ze_span

	# Stage 2: Sediment Deposition
	var sediment := PackedFloat32Array()
	sediment.resize(n)
	sediment.fill(0.0)

	if dep_strength > 0.0 and dep_radius > 0.0:
		var cell_m: float = maxf(minf(cell_dx, cell_dz), 1.0e-4)
		var ir: int = maxi(1, int(round(dep_radius / cell_m)))
		ir = mini(ir, maxi(1, mini(p_gw, p_gh) / 2))
		var z_fill := z.duplicate()
		for iz in range(p_gh):
			for ix in range(p_gw):
				var idx: int = iz * p_gw + ix
				var max_n: float = z_fill[idx]
				for dy_i in range(-ir, ir + 1):
					var ny: int = iz + dy_i
					if ny < 0 or ny >= p_gh: continue
					for dx_i in range(-ir, ir + 1):
						var nx: int = ix + dx_i
						if nx < 0 or nx >= p_gw: continue
						if dx_i * dx_i + dy_i * dy_i <= ir * ir:
							max_n = maxf(max_n, z_fill[ny * p_gw + nx])
				z_fill[idx] = 0.5 * (z_fill[idx] + max_n)

		for i in range(n):
			var d_val: float = maxf(0.0, z_fill[i] - z[i])
			var dep: float = dep_strength * d_val
			z[i] += dep
			sediment[i] = dep * relief_ref

	# Stage 3: Fine Stream Power Incision
	if str_strength > 0.0:
		for k in range(n - 1, -1, -1):
			var idx: int = order_final[k]
			var r: int = receivers[idx]
			if r != idx:
				var ix: int = idx % p_gw
				var iz: int = idx / p_gw
				var rx: int = r % p_gw
				var rz: int = r / p_gw
				var d: float = maxf(sqrt(pow(float(ix - rx) * dx, 2.0) + pow(float(iz - rz) * dz, 2.0)), 1.0e-5)
				var slope: float = maxf(0.0, (z[idx] - z[r]) / d)
				var stream_inc: float = str_strength * log(1.0 + pow(maxf(area_acc[idx], cell_area), str_exp) * slope) * erodibility[idx] * 0.15
				z[idx] = maxf(z[r], z[idx] - stream_inc)

	# Stage 4: Post-Processing
	if enable_post_smooth or bank_smoothing > 0.0:
		var smoothed := z.duplicate()
		var blend: float = 0.3 if enable_post_smooth else (bank_smoothing * 0.4)
		for iz in range(1, p_gh - 1):
			for ix in range(1, p_gw - 1):
				var idx: int = iz * p_gw + ix
				var avg: float = 0.25 * (z[iz * p_gw + ix - 1] + z[iz * p_gw + ix + 1] +
						z[(iz - 1) * p_gw + ix] + z[(iz + 1) * p_gw + ix])
				smoothed[idx] = (1.0 - blend) * z[idx] + blend * avg
		z = smoothed

	var final_height := PackedFloat32Array()
	final_height.resize(n)
	var eroded_rock := PackedFloat32Array()
	eroded_rock.resize(n)

	for i in range(n):
		var orig_h: float = p_surface[i]
		if not is_finite(orig_h):
			final_height[i] = orig_h
			eroded_rock[i] = 0.0
			continue

		var eroded_h: float = zmin + z[i] * relief_ref
		var m_val: float = mask[i] if has_mask else 1.0
		var eff_weight: float = erosion_strength * m_val

		var res_h: float = (1.0 - eff_weight) * orig_h + eff_weight * eroded_h
		final_height[i] = res_h
		eroded_rock[i] = maxf(0.0, orig_h - res_h)

	return [final_height, eroded_rock, sediment]


func _param_changed() -> void:
	mark_dirty_since_bake()
	emit_changed()
