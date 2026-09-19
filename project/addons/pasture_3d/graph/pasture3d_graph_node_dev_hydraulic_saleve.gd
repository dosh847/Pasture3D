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

@export_group("Control Points")
## How many control points the drainage network is solved on. Channels are about one point apart, so
## more points give finer valleys. Ignored when Point Spacing is set.
@export_range(500, 100000, 100, "or_greater") var control_points: int = 15000:
	set(v):
		control_points = clampi(v, 16, 1000000)
		_param_changed()

## Distance between control points, in metres. 0 derives it from Control Points over the solved area,
## which moves when the area does (a Modifier Margin). Set it to hold the network steady across margins:
## the point lattice is anchored to the world, so a wider area adds points without moving any.
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m") var point_spacing: float = 0.0:
	set(v):
		point_spacing = maxf(v, 0.0)
		_param_changed()

enum Reconstruction { LINEAR, GRADIENT }
## How the solved points become the grid. Gradient blends each point's tangent plane for smooth valley
## walls; Linear is flat within each triangle.
@export var reconstruction: Reconstruction = Reconstruction.GRADIENT:
	set(v):
		reconstruction = v
		_param_changed()

@export_group("Warp")
## Adds seeded fBm to the dx/dy warp, so valleys meander instead of following triangle edges.
@export var default_warp: bool = true:
	set(v):
		default_warp = v
		_param_changed()

## Warp distance in metres. 0 = 2% of the smaller side of the solved area.
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m") var warp_amount: float = 0.0:
	set(v):
		warp_amount = maxf(v, 0.0)
		_param_changed()

## Warp feature size in metres. 0 = a quarter of the smaller side of the solved area.
@export_range(0.0, 1000.0, 1.0, "or_greater", "suffix:m") var warp_size: float = 0.0:
	set(v):
		warp_size = maxf(v, 0.0)
		_param_changed()

@export_group("Sediment Deposition (Stage 2)")
## Fill-blur radius in METRES, 0 = 10% of the smaller side (mirrors the native node).
@export_range(0.0, 200.0, 0.5, "or_greater", "suffix:m") var deposition_radius: float = 0.0:
	set(v):
		deposition_radius = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 1.0, 0.01) var deposition_strength: float = 0.5:
	set(v):
		deposition_strength = clampf(v, 0.0, 1.0)
		_param_changed()

@export_group("Fine River Incision (Stage 3)")
@export_range(0.0, 1.0, 0.005) var stream_strength: float = 0.15:
	set(v):
		stream_strength = clampf(v, 0.0, 1.0)
		_param_changed()

@export_range(0.01, 1.0, 0.01) var stream_exp: float = 0.5:
	set(v):
		stream_exp = clampf(v, 0.01, 1.0)
		_param_changed()

@export_group("Rim")
@export_range(0.0, 500.0, 0.5, "or_greater", "suffix:m") var rim_width: float = 0.0:
	set(v):
		rim_width = maxf(v, 0.0)
		_param_changed()

@export_range(0.0, 0.5, 0.005) var outlet_level: float = 0.1:
	set(v):
		outlet_level = clampf(v, 0.0, 1.0)
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
		"control_points": control_points,
		"point_spacing": point_spacing,
		"reconstruction": int(reconstruction),
		"default_warp": default_warp,
		"warp_amount": warp_amount,
		"warp_size": warp_size,
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
		"rim_width": rim_width,
		"outlet_level": outlet_level,
	}

	# This node offered FROZEN, a Bake button and a stale flag over a cache that was never written:
	# the solve ran on every evaluation whatever the setting said, and `_param_changed` set `_stale`
	# on a freeze that did not exist. The freeze was UI. It is now the same one every other solver
	# uses.
	var r: Array = solve_cached(solver_cache_key(p_gw, p_gh, [surface, dx_in, dy_in, mask_in]),
			func(): return solve_gd(surface, p_gw, p_gh, p_rect, p))
	if r.size() < 5:
		return r
	return [r[0], r[1], r[2]]


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


# Bilinear sample, cell centres at (i + 0.5) * cell. Mirrors saleve_sample.
static func _sample(p_h: PackedFloat32Array, p_gw: int, p_gh: int, p_x0: float, p_z0: float, p_cdx: float, p_cdz: float, p_x: float, p_z: float) -> float:
	var gx: float = clampf((p_x - p_x0) / p_cdx - 0.5, -0.5, float(p_gw) - 0.5)
	var gz: float = clampf((p_z - p_z0) / p_cdz - 0.5, -0.5, float(p_gh) - 0.5)
	var ix: int = clampi(int(floor(gx)), 0, p_gw - 2)
	var iz: int = clampi(int(floor(gz)), 0, p_gh - 2)
	var tx: float = gx - ix
	var tz: float = gz - iz
	var a: float = p_h[iz * p_gw + ix]
	var b: float = p_h[iz * p_gw + ix + 1]
	var c: float = p_h[(iz + 1) * p_gw + ix]
	var d: float = p_h[(iz + 1) * p_gw + ix + 1]
	var top: float = a + (b - a) * tx
	var bot: float = c + (d - c) * tx
	return top + (bot - top) * tz


static func _fbm(p_x: float, p_z: float, p_seed: int) -> float:
	var sum: float = 0.0
	var amp: float = 1.0
	var norm: float = 0.0
	var f: float = 1.0
	for o in range(4):
		sum += amp * _value_noise(p_x * f, p_z * f, (p_seed + o * 101) & 0xffffffff)
		norm += amp
		amp *= 0.5
		f *= 2.0
	return sum / norm


# Odd reflection past either end of a strided run (mirrors the native blur).
static func _odd(p_a: PackedFloat32Array, p_base: int, p_stride: int, p_len: int, p_i: int) -> float:
	if p_i < 0:
		return 2.0 * p_a[p_base] - p_a[p_base - p_i * p_stride]
	if p_i >= p_len:
		return 2.0 * p_a[p_base + (p_len - 1) * p_stride] - p_a[p_base + (2 * (p_len - 1) - p_i) * p_stride]
	return p_a[p_base + p_i * p_stride]


## Where material settles on a surface (mirrors `saleve_settle`): the priority-flood fill, raised to its
## odd-reflected blur. Returns [target, flat]; `target - surface` is the settling depth.
static func _settle(p_surf: PackedFloat32Array, p_valid: PackedFloat32Array, p_gw: int, p_gh: int, p_ir: int,
		p_cell_dx: float, p_cell_dz: float, p_flat_from_fill: bool) -> Array:
	var n := p_gw * p_gh
	var filled := p_surf.duplicate()
	var done := PackedByteArray()
	done.resize(n)
	var hk: Array = []
	var hv: Array = []
	for iz in range(p_gh):
		for ix in range(p_gw):
			var i: int = iz * p_gw + ix
			if not is_finite(p_valid[i]) or ix == 0 or iz == 0 or ix == p_gw - 1 or iz == p_gh - 1:
				done[i] = 1
				_heap_push(hk, hv, filled[i], i)
	while not hk.is_empty():
		var ev: float = hk[0]
		var ei: int = hv[0]
		_heap_pop(hk, hv)
		var cx: int = ei % p_gw
		var cz: int = ei / p_gw
		for dz in range(-1, 2):
			for dxo in range(-1, 2):
				var nx: int = cx + dxo
				var nz: int = cz + dz
				if (dxo == 0 and dz == 0) or nx < 0 or nz < 0 or nx >= p_gw or nz >= p_gh:
					continue
				var j: int = nz * p_gw + nx
				if done[j] != 0:
					continue
				done[j] = 1
				filled[j] = maxf(filled[j], ev)
				_heap_push(hk, hv, filled[j], j)
	var ir := p_ir
	var inv: float = 1.0 / float(2 * ir + 1)
	var tmp := PackedFloat32Array()
	tmp.resize(n)
	var blur := PackedFloat32Array()
	blur.resize(n)
	for iz in range(p_gh):
		for ix in range(p_gw):
			var acc: float = 0.0
			for k in range(-ir, ir + 1):
				acc += _odd(filled, iz * p_gw, 1, p_gw, ix + k)
			tmp[iz * p_gw + ix] = acc * inv
	for iz in range(p_gh):
		for ix in range(p_gw):
			var acc: float = 0.0
			for k in range(-ir, ir + 1):
				acc += _odd(tmp, ix, p_gw, p_gh, iz + k)
			blur[iz * p_gw + ix] = acc * inv
	var target := PackedFloat32Array()
	target.resize(n)
	var flat := PackedFloat32Array()
	flat.resize(n)
	var fs: PackedFloat32Array = filled if p_flat_from_fill else blur
	for iz in range(p_gh):
		for ix in range(p_gw):
			var i: int = iz * p_gw + ix
			var xl: int = maxi(ix - 1, 0)
			var xr: int = mini(ix + 1, p_gw - 1)
			var zl: int = maxi(iz - 1, 0)
			var zr: int = mini(iz + 1, p_gh - 1)
			var gxs: float = (fs[iz * p_gw + xr] - fs[iz * p_gw + xl]) / (maxi(xr - xl, 1) * p_cell_dx)
			var gzs: float = (fs[zr * p_gw + ix] - fs[zl * p_gw + ix]) / (maxi(zr - zl, 1) * p_cell_dz)
			flat[i] = clampf(1.0 - sqrt(gxs * gxs + gzs * gzs) / 0.5, 0.0, 1.0)
			target[i] = maxf(filled[i], blur[i])
	return [target, flat]


static func solve_gd(p_surface: PackedFloat32Array, p_gw: int, p_gh: int, p_rect: Rect2, p_params: Dictionary) -> Array:
	var n: int = p_gw * p_gh
	if p_surface.size() != n or p_gw < 2 or p_gh < 2:
		var empty := PackedFloat32Array()
		empty.resize(n)
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
	var lower_only: bool = bool(p_params.get("lower_only", true))
	var cap_everywhere: bool = bool(p_params.get("cap_everywhere", false))
	var outlet_level_f: float = clampf(float(p_params.get("outlet_level", 0.1)), 0.0, 1.0)
	var flat_from_fill: bool = bool(p_params.get("flat_from_fill", false))
	var stable_noise: bool = bool(p_params.get("stable_noise", true))
	var erosion_strength: float = clampf(float(p_params.get("erosion_strength", 0.7)), 0.0, 1.0)
	var m_exp: float = clampf(float(p_params.get("drainage_exponent", 0.15)), 0.01, 0.8)
	var noise_strength: float = maxf(0.0, float(p_params.get("drainage_noise", 0.15)))
	var shape_preservation: float = clampf(float(p_params.get("shape_preservation", 2.0)), 0.1, 4.0)
	var bank_smoothing: float = clampf(float(p_params.get("bank_smoothing", 0.0)), 0.0, 0.5)
	var p_seed: int = int(p_params.get("seed", 0))
	var reference_relief: float = maxf(0.0, float(p_params.get("reference_relief", 0.0)))
	var dep_radius: float = maxf(0.0, float(p_params.get("deposition_radius", 0.0)))
	var dep_strength: float = clampf(float(p_params.get("deposition_strength", 0.5)), 0.0, 1.0)
	var str_strength: float = clampf(float(p_params.get("stream_strength", 0.15)), 0.0, 1.0)
	var str_exp: float = clampf(float(p_params.get("stream_exp", 0.5)), 0.01, 1.0)
	var enable_post_smooth: bool = bool(p_params.get("enable_post_smoothing", false))
	var control_points: int = clampi(int(p_params.get("control_points", 15000)), 16, 1000000)
	var point_spacing: float = maxf(0.0, float(p_params.get("point_spacing", 0.0)))
	var recon: int = clampi(int(p_params.get("reconstruction", 1)), 0, 2)
	var default_warp: bool = bool(p_params.get("default_warp", true))
	var warp_amount: float = maxf(0.0, float(p_params.get("warp_amount", 0.0)))
	var warp_size: float = maxf(0.0, float(p_params.get("warp_size", 0.0)))
	var grid_solve: bool = bool(p_params.get("grid_solve", false))
	var reconstruct_only: bool = bool(p_params.get("reconstruct_only", false))

	var zmin: float = INF
	var zmax: float = -INF
	for v in p_surface:
		if is_finite(v):
			if v < zmin: zmin = v
			if v > zmax: zmax = v
	if zmax - zmin < 1.0e-5:
		var zeroes := PackedFloat32Array()
		zeroes.resize(n)
		return [p_surface.duplicate(), zeroes.duplicate(), zeroes]

	# float32 like the native solver's zmin/zmax/zptp
	var zptp: float = float(PackedFloat32Array([zmax - zmin])[0])
	var relief_ref: float = reference_relief if reference_relief > 0.0 else zptp
	var vref: float = maxf(relief_ref, 1.0e-5)
	var x0: float = p_rect.position.x
	var z0: float = p_rect.position.y
	var rw: float = p_rect.size.x if p_rect.size.x > 0.0 else float(p_gw)
	var rh: float = p_rect.size.y if p_rect.size.y > 0.0 else float(p_gh)
	var cell_dx: float = rw / float(p_gw)
	var cell_dz: float = rh / float(p_gh)
	var min_side: float = minf(rw, rh)

	# ---- the drainage graph ----
	var nv: int = 0
	var px := PackedFloat64Array()
	var pz := PackedFloat64Array()
	var outlet := PackedByteArray()
	var area := PackedFloat64Array()
	var vh := PackedFloat64Array()
	var nbr_start := PackedInt32Array()
	var nbr := PackedInt32Array()
	var nbr_len := PackedFloat64Array()
	var tris := PackedInt32Array()
	if grid_solve:
		nv = n
		px.resize(n)
		pz.resize(n)
		outlet.resize(n)
		area.resize(n)
		area.fill((cell_dx / vref) * (cell_dz / vref))
		vh.resize(n)
		var n_dx: Array[int] = [-1, 1, 0, 0, -1, 1, -1, 1]
		var n_dz: Array[int] = [0, 0, -1, 1, -1, -1, 1, 1]
		var ddx: float = cell_dx / vref
		var ddz: float = cell_dz / vref
		var diag: float = sqrt(ddx * ddx + ddz * ddz)
		var n_dist: Array[float] = [ddx, ddx, ddz, ddz, diag, diag, diag, diag]
		nbr_start.resize(n + 1)
		for idx in range(n):
			var ix: int = idx % p_gw
			var iz: int = idx / p_gw
			px[idx] = x0 + (ix + 0.5) * cell_dx
			pz[idx] = z0 + (iz + 0.5) * cell_dz
			vh[idx] = p_surface[idx]
			outlet[idx] = 1 if (ix == 0 or iz == 0 or ix == p_gw - 1 or iz == p_gh - 1) else 0
			nbr_start[idx] = nbr.size()
			for k in range(8):
				var nx: int = ix + n_dx[k]
				var nz: int = iz + n_dz[k]
				if nx >= 0 and nx < p_gw and nz >= 0 and nz < p_gh:
					nbr.append(nz * p_gw + nx)
					nbr_len.append(n_dist[k])
		nbr_start[n] = nbr.size()
	else:
		var s: float = point_spacing if point_spacing > 0.0 else sqrt(rw * rh / float(maxi(control_points, 16)))
		s = maxf(s, maxf(cell_dx, cell_dz))
		var pts := PackedVector2Array()
		var ring := PackedByteArray()
		var ex: int = maxi(1, int(roundf(rw / s)))
		var ez: int = maxi(1, int(roundf(rh / s)))
		for k in range(ex + 1):
			pts.append(Vector2(x0 + rw * k / ex, z0)); ring.append(1)
			pts.append(Vector2(x0 + rw * k / ex, z0 + rh)); ring.append(1)
		for k in range(1, ez):
			pts.append(Vector2(x0, z0 + rh * k / ez)); ring.append(1)
			pts.append(Vector2(x0 + rw, z0 + rh * k / ez)); ring.append(1)
		var jseed: int = (p_seed ^ 0x51ed27) & 0xffffffff
		var i_lo: int = int(floor(x0 / s))
		var i_hi: int = int(floor((x0 + rw) / s))
		var j_lo: int = int(floor(z0 / s))
		var j_hi: int = int(floor((z0 + rh) / s))
		var inset: float = 0.4 * s
		for j in range(j_lo, j_hi + 1):
			for i in range(i_lo, i_hi + 1):
				var key: int = _lattice_key(i, j)
				var jx: float = 0.35 * _fast_hash_to_unit(jseed, key)
				var jz: float = 0.35 * _fast_hash_to_unit((jseed + 1) & 0xffffffff, key)
				var x: float = (i + 0.5 + jx) * s
				var z: float = (j + 0.5 + jz) * s
				if x > x0 + inset and x < x0 + rw - inset and z > z0 + inset and z < z0 + rh - inset:
					pts.append(Vector2(x, z)); ring.append(0)
		nv = pts.size()
		var tri := Geometry2D.triangulate_delaunay(pts)
		px.resize(nv)
		pz.resize(nv)
		outlet.resize(nv)
		area.resize(nv)
		vh.resize(nv)
		for i in range(nv):
			px[i] = pts[i].x
			pz[i] = pts[i].y
			outlet[i] = ring[i]
			vh[i] = _sample(p_surface, p_gw, p_gh, x0, z0, cell_dx, cell_dz, px[i], pz[i])
		var adj: Array = []
		adj.resize(nv)
		for i in range(nv):
			adj[i] = []
		for t in range(tri.size() / 3):
			var a: int = tri[t * 3]
			var b: int = tri[t * 3 + 1]
			var c: int = tri[t * 3 + 2]
			var ar: float = 0.5 * absf((px[b] - px[a]) * (pz[c] - pz[a]) - (px[c] - px[a]) * (pz[b] - pz[a]))
			if ar < 1.0e-9 * s * s:
				continue
			tris.append(a); tris.append(b); tris.append(c)
			var third: float = ar / 3.0 / (vref * vref)
			area[a] += third
			area[b] += third
			area[c] += third
			adj[a].append(b); adj[a].append(c)
			adj[b].append(a); adj[b].append(c)
			adj[c].append(a); adj[c].append(b)
		nbr_start.resize(nv + 1)
		for i in range(nv):
			var l: Array = adj[i]
			l.sort()
			nbr_start[i] = nbr.size()
			var last: int = -1
			for j in l:
				if j == last:
					continue
				last = j
				nbr.append(j)
				var ddx: float = px[j] - px[i]
				var ddz: float = pz[j] - pz[i]
				nbr_len.append(sqrt(ddx * ddx + ddz * ddz) / vref)
		nbr_start[nv] = nbr.size()

	var z := PackedFloat32Array()
	z.resize(nv)
	var erodibility := PackedFloat32Array()
	erodibility.resize(nv)
	erodibility.fill(1.0)
	for i in range(nv):
		var h: float = vh[i]
		if not is_finite(h):
			z[i] = 0.0
			outlet[i] = 1
			continue
		z[i] = (h - zmin) / zptp
		if outlet_level_f > 0.0 and z[i] <= outlet_level_f:
			outlet[i] = 1
		erodibility[i] = pow(clampf(1.0 - (h - zmin) / vref, 0.01, 1.0), shape_preservation)

	var receivers := PackedInt32Array()
	var area_acc := PackedFloat32Array()
	var tree := {}
	if not reconstruct_only:
		var fseed: int = (p_seed ^ 0x9e3779b9) & 0xffffffff
		for i in range(nv):
			if is_finite(vh[i]):
				z[i] = z[i] + 1.0e-3 * _value_noise(px[i] / 50.0, pz[i] / 50.0, fseed)
		var slope_cap := PackedFloat32Array()
		slope_cap.resize(nv)
		var cx: float = x0 + 0.5 * rw
		var cz: float = z0 + 0.5 * rh
		var to_unit: float = vref / zptp
		for i in range(nv):
			var r: float = sqrt((px[i] - cx) * (px[i] - cx) + (pz[i] - cz) * (pz[i] - cz)) / maxf(min_side, 1.0e-6)
			var pulse: float = (1.0 - r * r * (3.0 - 2.0 * r)) if r < 1.0 else 0.0
			slope_cap[i] = (slope_border + (slope_center - slope_border) * pulse) * to_unit

		# ---- Stage 1 ----
		receivers.resize(nv)
		area_acc.resize(nv)
		var response_times := PackedFloat32Array()
		response_times.resize(nv)
		for iter in range(iters):
			var pass_seed: int = p_seed if stable_noise else p_seed + iter * 17
			for idx in range(nv):
				if outlet[idx] == 1:
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
						var score: float = slope * (1.0 + noise_strength * noise)
						if score > best_score:
							best_score = score
							best = n_idx
				receivers[idx] = best

			tree = _build_tree(receivers, nv)
			var root_of: PackedInt32Array = tree.root_of
			var any_pit: bool = false
			var basin_drained := PackedByteArray()
			basin_drained.resize(nv)
			for i in range(nv):
				basin_drained[i] = outlet[i]
				if receivers[i] == i and outlet[i] == 0:
					any_pit = true
			if any_pit and reroute:
				var settled := PackedByteArray()
				settled.resize(nv)
				var dist := PackedFloat64Array()
				dist.resize(nv)
				dist.fill(INF)
				var pred := PackedInt32Array()
				pred.resize(nv)
				pred.fill(-1)
				var hk: Array = []
				var hv: Array = []
				for i in range(nv):
					if outlet[i] == 1:
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
				tree = _build_tree(receivers, nv)
				root_of = tree.root_of

			var order: PackedInt32Array = tree.order
			for i in range(nv):
				area_acc[i] = area[i]
			for k in range(nv - 1, -1, -1):
				var idx: int = order[k]
				var r: int = receivers[idx]
				if r != idx:
					area_acc[r] += area_acc[idx]
			for k in range(nv):
				var idx: int = order[k]
				var r: int = receivers[idx]
				if r == idx:
					response_times[idx] = 0.0
					continue
				var d: float = maxf(_edge_len(nbr_start, nbr, nbr_len, idx, r), 1.0e-5)
				var celerity: float = erodibility[idx] * pow(maxf(area_acc[idx], area[idx]), m_exp)
				response_times[idx] = response_times[r] + (d / maxf(celerity, 1.0e-4))
			var diff: float = 0.0
			for k in range(nv):
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
			if diff / float(nv) < tolerance * maxf(zhi - zlo, 1.0e-5):
				break

		var lo: float = INF
		var hi: float = -INF
		for v in z:
			lo = minf(lo, v)
			hi = maxf(hi, v)
		var span: float = maxf(hi - lo, 1.0e-5)
		for i in range(nv):
			z[i] = (z[i] - lo) / span

	# ---- reconstruction ----
	var zg := PackedFloat32Array()
	zg.resize(n)
	if grid_solve:
		for i in range(n):
			zg[i] = z[i]
	else:
		var gx := PackedFloat64Array()
		gx.resize(nv)
		var gz := PackedFloat64Array()
		gz.resize(nv)
		if recon == 1:
			for i in range(nv):
				var sxx: float = 0.0
				var sxz: float = 0.0
				var szz: float = 0.0
				var sx: float = 0.0
				var sz: float = 0.0
				for e in range(nbr_start[i], nbr_start[i + 1]):
					var j: int = nbr[e]
					var ex_: float = px[j] - px[i]
					var ez_: float = pz[j] - pz[i]
					var w: float = 1.0 / maxf(ex_ * ex_ + ez_ * ez_, 1.0e-12)
					var dzv: float = z[j] - z[i]
					sxx += w * ex_ * ex_
					sxz += w * ex_ * ez_
					szz += w * ez_ * ez_
					sx += w * ex_ * dzv
					sz += w * ez_ * dzv
				var det: float = sxx * szz - sxz * sxz
				if absf(det) > 1.0e-12 * maxf(sxx * szz, 1.0e-30):
					gx[i] = (szz * sx - sxz * sz) / det
					gz[i] = (sxx * sz - sxz * sx) / det
		var nt: int = tris.size() / 3
		var bs: float = maxf(sqrt(rw * rh / maxi(nv, 1)) * 1.5, 1.0e-6)
		var bw: int = maxi(1, int(ceil(rw / bs)))
		var bh: int = maxi(1, int(ceil(rh / bs)))
		var buckets: Array = []
		buckets.resize(bw * bh)
		for i in range(bw * bh):
			buckets[i] = []
		for t in range(nt):
			var mnx: float = INF
			var mxx: float = -INF
			var mnz: float = INF
			var mxz: float = -INF
			for k in range(3):
				var v: int = tris[t * 3 + k]
				mnx = minf(mnx, px[v]); mxx = maxf(mxx, px[v])
				mnz = minf(mnz, pz[v]); mxz = maxf(mxz, pz[v])
			var bx0: int = clampi(int(floor((mnx - x0) / bs)), 0, bw - 1)
			var bx1: int = clampi(int(floor((mxx - x0) / bs)), 0, bw - 1)
			var bz0: int = clampi(int(floor((mnz - z0) / bs)), 0, bh - 1)
			var bz1: int = clampi(int(floor((mxz - z0) / bs)), 0, bh - 1)
			for bz in range(bz0, bz1 + 1):
				for bx in range(bx0, bx1 + 1):
					buckets[bz * bw + bx].append(t)
		var w_amp: float = warp_amount if warp_amount > 0.0 else 0.02 * min_side
		var w_size: float = maxf(warp_size if warp_size > 0.0 else 0.25 * min_side, 1.0e-6)
		var wseed: int = (p_seed ^ 0x7f4a7c15) & 0xffffffff
		for iz in range(p_gh):
			for ix in range(p_gw):
				var idx: int = iz * p_gw + ix
				var qx: float = x0 + (ix + 0.5) * cell_dx
				var qz: float = z0 + (iz + 0.5) * cell_dz
				var wx: float = dx_arr[idx] if has_dx else 0.0
				var wz: float = dy_arr[idx] if has_dy else 0.0
				if default_warp and not reconstruct_only:
					wx += w_amp * _fbm(qx / w_size, qz / w_size, wseed)
					wz += w_amp * _fbm(qx / w_size, qz / w_size, (wseed + 7919) & 0xffffffff)
				if wx != 0.0 or wz != 0.0:
					var u: float = (qx - x0) / rw
					var v: float = (qz - z0) / rh
					var fade: float = clampf(16.0 * u * (1.0 - u) * v * (1.0 - v), 0.0, 1.0)
					qx = clampf(qx + fade * wx, x0, x0 + rw)
					qz = clampf(qz + fade * wz, z0, z0 + rh)
				var bx: int = clampi(int(floor((qx - x0) / bs)), 0, bw - 1)
				var bz: int = clampi(int(floor((qz - z0) / bs)), 0, bh - 1)
				var best_t: int = -1
				var best_min: float = -1.0e300
				var b0: float = 0.0
				var b1: float = 0.0
				var b2: float = 0.0
				for t in buckets[bz * bw + bx]:
					var a: int = tris[t * 3]
					var b: int = tris[t * 3 + 1]
					var c: int = tris[t * 3 + 2]
					var d: float = (pz[b] - pz[c]) * (px[a] - px[c]) + (px[c] - px[b]) * (pz[a] - pz[c])
					if absf(d) < 1.0e-18:
						continue
					var l0: float = ((pz[b] - pz[c]) * (qx - px[c]) + (px[c] - px[b]) * (qz - pz[c])) / d
					var l1: float = ((pz[c] - pz[a]) * (qx - px[c]) + (px[a] - px[c]) * (qz - pz[c])) / d
					var l2: float = 1.0 - l0 - l1
					var mn: float = minf(l0, minf(l1, l2))
					if mn > best_min:
						best_min = mn
						best_t = t
						b0 = l0; b1 = l1; b2 = l2
						if mn >= -1.0e-9:
							break
				if best_t < 0:
					zg[idx] = 0.0
					continue
				if best_min < 0.0:
					b0 = maxf(b0, 0.0); b1 = maxf(b1, 0.0); b2 = maxf(b2, 0.0)
					var sm: float = maxf(b0 + b1 + b2, 1.0e-12)
					b0 /= sm; b1 /= sm; b2 /= sm
				var vv: Array[int] = [tris[best_t * 3], tris[best_t * 3 + 1], tris[best_t * 3 + 2]]
				var bb: Array[float] = [b0, b1, b2]
				var val: float = 0.0
				if recon == 2:
					var m: int = 0
					for k in range(1, 3):
						if bb[k] > bb[m]:
							m = k
					val = z[vv[m]]
				elif recon == 0:
					val = bb[0] * z[vv[0]] + bb[1] * z[vv[1]] + bb[2] * z[vv[2]]
				else:
					var ws: float = 0.0
					for k in range(3):
						var vtx: int = vv[k]
						var w: float = bb[k] * bb[k]
						val += w * (z[vtx] + gx[vtx] * (qx - px[vtx]) + gz[vtx] * (qz - pz[vtx]))
						ws += w
					val /= maxf(ws, 1.0e-30)
				zg[idx] = val

	if reconstruct_only:
		var out := PackedFloat32Array()
		out.resize(n)
		for i in range(n):
			out[i] = (zmin + zg[i] * zptp) if is_finite(p_surface[i]) else p_surface[i]
		var zz := PackedFloat32Array()
		zz.resize(n)
		return [out, zz.duplicate(), zz]

	# The grid in METRES from here on (mirrors the native solve).
	var hm := PackedFloat32Array()
	hm.resize(n)
	var rim_w: float = maxf(float(p_params.get("rim_width", 0.0)), 0.0)
	var rim: float = rim_w if rim_w > 0.0 else 0.1 * min_side
	for i in range(n):
		hm[i] = zmin + zg[i] * relief_ref
	for i in range(n):
		if lower_only and is_finite(p_surface[i]) and hm[i] > p_surface[i]:
			var w := 1.0
			if not cap_everywhere:
				var ix := i % p_gw
				var iz := i / p_gw
				var d: float = minf(minf((ix + 0.5) * cell_dx, (p_gw - 0.5 - ix) * cell_dx),
						minf((iz + 0.5) * cell_dz, (p_gh - 0.5 - iz) * cell_dz))
				var t: float = clampf(d / maxf(rim, 1.0e-6), 0.0, 1.0)
				w = 1.0 - t * t * (3.0 - 2.0 * t)
			hm[i] = hm[i] + w * (p_surface[i] - hm[i])

	# ---- Stage 2: the settling fill applied to the Stage 1 surface ----
	var radius_m: float = dep_radius if dep_radius > 0.0 else 0.1 * min_side
	var cell_m: float = maxf(minf(cell_dx, cell_dz), 1.0e-4)
	var settle_ir: int = clampi(int(round(radius_m / cell_m)), 1, maxi(1, mini(p_gw, p_gh) / 2 - 1))
	var st: Array = _settle(hm, p_surface, p_gw, p_gh, settle_ir, cell_dx, cell_dz, flat_from_fill)
	var target: PackedFloat32Array = st[0]
	var flat: PackedFloat32Array = st[1]
	# Stage 1's valleys, for eroded_rock, measured before Stage 2 fills them.
	var valley1 := PackedFloat32Array()
	valley1.resize(n)
	for i in range(n):
		valley1[i] = maxf(0.0, target[i] - hm[i])
	var dep := PackedFloat32Array()
	dep.resize(n)
	if dep_strength > 0.0:
		for i in range(n):
			if not is_finite(p_surface[i]):
				continue
			dep[i] = dep_strength * flat[i] * (target[i] - hm[i])
			hm[i] += dep[i]

	var pre_stream := hm.duplicate()
	# ---- Stage 3: the stream-log oracle on the metric grid ----
	if str_strength > 0.0:
		var sl: Array = load("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_hydraulic_stream_log.gd").solve_oracle(
				hm, p_gw, p_gh, p_rect, {"incision_rate": str_strength, "area_exponent": str_exp})
		var sh: PackedFloat32Array = sl[0]
		if sh.size() == n:
			for i in range(n):
				if is_finite(sh[i]):
					hm[i] = sh[i]

	var post_stream := hm.duplicate()

	# ---- Stage 4 ----
	if enable_post_smooth or bank_smoothing > 0.0:
		var smoothed := hm.duplicate()
		var blend: float = 0.3 if enable_post_smooth else (bank_smoothing * 0.4)
		for iz in range(1, p_gh - 1):
			for ix in range(1, p_gw - 1):
				var idx: int = iz * p_gw + ix
				var avg: float = 0.25 * (hm[idx - 1] + hm[idx + 1] + hm[idx - p_gw] + hm[idx + p_gw])
				smoothed[idx] = (1.0 - blend) * hm[idx] + blend * avg
		hm = smoothed

	# The reported masks describe the FINAL surface (see the native composite): eroded_rock is Stage 1's valley
	# depth plus Stage 3's cut, sediment is the final surface's settling depth.
	var settle_depth := PackedFloat32Array()
	settle_depth.resize(n)
	if dep_strength > 0.0:
		var sf: Array = _settle(hm, p_surface, p_gw, p_gh, settle_ir, cell_dx, cell_dz, flat_from_fill)
		var t2: PackedFloat32Array = sf[0]
		for i in range(n):
			settle_depth[i] = dep_strength * maxf(0.0, t2[i] - hm[i])
	var final_height := PackedFloat32Array()
	final_height.resize(n)
	var eroded_rock := PackedFloat32Array()
	eroded_rock.resize(n)
	var sediment := PackedFloat32Array()
	sediment.resize(n)
	for i in range(n):
		var orig_h: float = p_surface[i]
		if not is_finite(orig_h):
			final_height[i] = orig_h
			continue
		var w: float = erosion_strength * (mask[i] if has_mask else 1.0)
		final_height[i] = (1.0 - w) * orig_h + w * hm[i]
		eroded_rock[i] = w * (valley1[i] + maxf(0.0, pre_stream[i] - post_stream[i]))
		sediment[i] = w * settle_depth[i]
	return [final_height, eroded_rock, sediment]


func _param_changed() -> void:
	mark_dirty_since_bake()
	emit_changed()

