# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevGavoronoise — the GDScript oracle twin for Gavoronoise (spec §7.2).
#
# The algorithm is defined once, in src/pasture_3d_gavoronoise.h. This is one of its three
# implementations; the others are the C++ kernel and the GAVORONOISE / GAVORONOISE_BASE shader modes. It
# exists because a generator with derivative feedback has no closed form to check against — the only way to
# know the kernel computes what was specified is to write the specification out a second time, slowly, and
# compare. Erosion stage after Clay John (MIT), base after Inigo Quilez (MIT); notices in the kernel header.
#
# The hash below is integer arithmetic masked to 32 bits at every step. GDScript ints are 64-bit, so the
# masks are not decoration: without them the multiplies keep their high bits, the values diverge from
# uint32 wraparound, and the oracle disagrees with both other implementations for reasons that look like
# an algorithm bug.
@tool
class_name Pasture3DGraphNodeDevGavoronoise
extends Pasture3DGraphNode

const U32 := 0xffffffff
const BASE_OCTAVES := 8
const GRAD_EPS := 0.1
const EROSION_SEED := 0x9e3779b9

@export var amplitude: float = 60.0:
	set(v):
		amplitude = v
		_param_changed()

@export var frequency: float = 0.002:
	set(v):
		frequency = v
		_param_changed()

@export var octaves: int = 8:
	set(v):
		octaves = v
		_param_changed()

@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

@export var angle_deg: float = 0.0:
	set(v):
		angle_deg = v
		_param_changed()

@export_range(0.0, 1.0, 0.01) var angle_spread: float = 1.0:
	set(v):
		angle_spread = v
		_param_changed()

@export var slope_strength: float = 1.0:
	set(v):
		slope_strength = v
		_param_changed()

@export var branch_strength: float = 2.0:
	set(v):
		branch_strength = v
		_param_changed()

@export_range(0.0, 1.0, 0.01) var z_cut_min: float = 0.2:
	set(v):
		z_cut_min = v
		_param_changed()

@export_range(0.0, 1.0, 0.01) var z_cut_max: float = 1.0:
	set(v):
		z_cut_max = v
		_param_changed()

@export var erosion_strength: float = 0.1:
	set(v):
		erosion_strength = v
		_param_changed()

@export var erosion_frequency: float = 4.0:
	set(v):
		erosion_frequency = v
		_param_changed()

@export var base_smoothing: float = 0.0:
	set(v):
		base_smoothing = v
		_param_changed()


@export var height_min: float = -INF:
	set(v):
		height_min = v
		_param_changed()

@export var height_max: float = -INF:
	set(v):
		height_max = v
		_param_changed()

@export var variation: float = 0.0:
	set(v):
		variation = v
		_param_changed()


## [lo, hi]. The rule is on GavoronoiseParams::height_min.
func _range(p_base: PackedFloat32Array) -> Array:
	var bmin := INF
	var bmax := -INF
	for v in p_base:
		if is_finite(v):
			bmin = minf(bmin, v)
			bmax = maxf(bmax, v)
	var has := bmax >= bmin
	var lo := height_min if is_finite(height_min) else (bmin if (height_min != -INF and has) else 0.0)
	var hi := height_max if is_finite(height_max) else (bmax if (height_max != -INF and has) else lo + amplitude)
	return [lo, hi]


## [x, z, gain]. Off at 0.
func _vary(p_x: float, p_z: float) -> Array:
	if variation <= 0.0:
		return [p_x, p_z, 1.0]
	var nx := _gabor(p_x * 0.5, p_z * 0.5, 1.0, 0.0, 1.0, (seed + 101) & U32)
	var nz := _gabor(p_x * 0.5, p_z * 0.5, 0.0, 1.0, 1.0, (seed + 211) & U32)
	var ns := _gabor(p_x * 0.25, p_z * 0.25, 1.0, 0.0, 1.0, (seed + 307) & U32)
	return [p_x + variation * nx, p_z + variation * nz, maxf(0.0, 1.0 + 2.0 * variation * ns)]


func op() -> StringName:
	return &"dev_gavoronoise"


func role() -> Role:
	return Role.GENERATOR


func needs_grid() -> bool:
	return true


func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"base", PortType.HEIGHT).require(),
	]


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and p_inputs[0].size() == p_gw * p_gh:
		return solve_base(p_gw, p_gh, p_rect, p_inputs[0])
	return solve(p_gw, p_gh, p_rect)


## The generator form.
func solve(p_gw: int, p_gh: int, p_rect: Rect2) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(p_gw * p_gh)
	var rng := _range(PackedFloat32Array())
	var lo: float = rng[0]
	var hr: float = rng[1] - lo
	if absf(hr) <= 1e-7 or frequency <= 0.0:
		out.fill(lo)
		return out
	var theta := angle_deg * TAU / 360.0
	var kx := -sin(theta)
	var kz := cos(theta)
	var spread := clampf(angle_spread, 0.0, 1.0)
	for iz in p_gh:
		for ix in p_gw:
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_gw, p_gh, p_rect)
			var vy := _vary(w.x * frequency, w.y * frequency)
			var px: float = vy[0]
			var pz: float = vy[1]
			var b := _base(px, pz, kx, kz, spread)
			var mx := _base(px + GRAD_EPS, pz, kx, kz, spread) - _base(px - GRAD_EPS, pz, kx, kz, spread)
			var mz := _base(px, pz + GRAD_EPS, kx, kz, spread) - _base(px, pz - GRAD_EPS, kx, kz, spread)
			var dx := mz / GRAD_EPS * 0.5 * slope_strength
			var dz := -mx / GRAD_EPS * 0.5 * slope_strength
			var v: float = b + erosion_strength * vy[2] * _erosion(px, pz, b, dx, dz)
			out[iz * p_gw + ix] = lo + hr * (0.5 * v + 0.5)
	return out


## The base-input form: erode p_base along its own slope.
func solve_base(p_gw: int, p_gh: int, p_rect: Rect2, p_base: PackedFloat32Array) -> PackedFloat32Array:
	var rng := _range(p_base)
	var lo: float = rng[0]
	var hr: float = rng[1] - lo
	if absf(hr) <= 1e-7 or frequency <= 0.0 or erosion_strength == 0.0:
		return p_base
	var sm: PackedFloat32Array = Pasture3DGraphNodeDevTerrainMetrics.new().box_mean(p_base, p_gw, p_gh, p_rect,
			base_smoothing) if base_smoothing > 0.0 else p_base
	var cdx := p_rect.size.x / float(p_gw)
	var cdz := p_rect.size.y / float(p_gh)
	var to_n := 2.0 / (hr * frequency)
	var out := PackedFloat32Array()
	out.resize(p_gw * p_gh)
	for iz in p_gh:
		for ix in p_gw:
			var i := iz * p_gw + ix
			var z := p_base[i]
			if not is_finite(z):
				out[i] = z
				continue
			var xm := maxi(ix - 1, 0)
			var xp := mini(ix + 1, p_gw - 1)
			var zm := maxi(iz - 1, 0)
			var zp := mini(iz + 1, p_gh - 1)
			var a0 := sm[iz * p_gw + xm]
			var a1 := sm[iz * p_gw + xp]
			var b0 := sm[zm * p_gw + ix]
			var b1 := sm[zp * p_gw + ix]
			var gx := 0.0
			var gz := 0.0
			if is_finite(a0) and is_finite(a1) and is_finite(b0) and is_finite(b1):
				gx = (a1 - a0) / (float(xp - xm) * cdx) * to_n
				gz = (b1 - b0) / (float(zp - zm) * cdz) * to_n
			var w := Pasture3DTerrainGraph.cell_to_world(ix, iz, p_gw, p_gh, p_rect)
			var bn := 2.0 * (z - lo) / hr - 1.0
			var vy := _vary(w.x * frequency, w.y * frequency)
			var e := _erosion(vy[0], vy[1], bn, gz * slope_strength, -gx * slope_strength)
			out[i] = z + erosion_strength * vy[2] * e * hr * 0.5
	return out


func _gabor(p_x: float, p_z: float, p_kx: float, p_kz: float, p_spread: float, p_seed: int) -> float:
	var flx := floorf(p_x)
	var flz := floorf(p_z)
	var bx := int(flx)
	var bz := int(flz)
	var fx := p_x - flx
	var fz := p_z - flz
	var av := 0.0
	var at := 0.0
	for j in range(-2, 3):
		for i in range(-2, 3):
			var cx := bx + i
			var cz := bz + j
			var rx := fx - (float(i) + _rnd01(_hash_cell(cx, cz, p_seed, 1)))
			var rz := fz - (float(j) + _rnd01(_hash_cell(cx, cz, p_seed, 2)))
			var kx := p_kx + p_spread * (2.0 * _rnd01(_hash_cell(cx, cz, p_seed, 3)) - 1.0)
			var kz := p_kz + p_spread * (2.0 * _rnd01(_hash_cell(cx, cz, p_seed, 4)) - 1.0)
			var kl := sqrt(kx * kx + kz * kz)
			if kl > 1e-9:
				kx /= kl
				kz /= kl
			else:
				kx = p_kx
				kz = p_kz
			var wt := exp(-4.0 * (rx * rx + rz * rz))
			av += wt * cos(TAU * (rx * kx + rz * kz))
			at += wt
	return av / at


func _base(p_x: float, p_z: float, p_kx: float, p_kz: float, p_spread: float) -> float:
	var n := 0.0
	var nf := 1.0
	var na := 0.6
	for o in BASE_OCTAVES:
		var v := _gabor(p_x * nf, p_z * nf, p_kx, p_kz, p_spread, (seed + o * 7919) & U32)
		n += v * na
		na *= minf(v + 1.0, 2.0) * 0.5
		na *= 0.5
		nf *= 2.0
	return n


## Returns [value, slope x, slope z].
func _eroder(p_x: float, p_z: float, p_dx: float, p_dz: float, p_seed: int) -> Array:
	var flx := floorf(p_x)
	var flz := floorf(p_z)
	var bx := int(flx)
	var bz := int(flz)
	var fx := p_x - flx
	var fz := p_z - flz
	var va := 0.0
	var vx := 0.0
	var vz := 0.0
	var wt := 0.0
	for j in range(-2, 3):
		for i in range(-2, 3):
			var cx := bx + i
			var cz := bz + j
			var rx := fx - (float(i) + 0.5 * _rnd01(_hash_cell(cx, cz, p_seed, 5)))
			var rz := fz - (float(j) + 0.5 * _rnd01(_hash_cell(cx, cz, p_seed, 6)))
			var w := exp(-2.0 * (rx * rx + rz * rz))
			var ph := TAU * (rx * p_dx + rz * p_dz)
			va += w * cos(ph)
			var s := -w * sin(ph)
			vx += s * p_dx
			vz += s * p_dz
			wt += w
	return [va / wt, vx / wt, vz / wt]


func _smoothstep01(p_lo: float, p_hi: float, p_x: float) -> float:
	if p_hi - p_lo <= 1e-9:
		return 1.0 if p_x >= p_hi else 0.0
	var t := clampf((p_x - p_lo) / (p_hi - p_lo), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _erosion(p_x: float, p_z: float, p_base: float, p_dx: float, p_dz: float) -> float:
	var hv := 0.0
	var hx := 0.0
	var hz := 0.0
	var a := 0.6 * _smoothstep01(z_cut_min, z_cut_max, p_base * 0.5 + 0.5)
	var f := 1.0
	for o in clampi(octaves, 1, 12):
		var e := _eroder(p_x * erosion_frequency * f, p_z * erosion_frequency * f, p_dx + branch_strength * hz, p_dz - branch_strength * hx,
				(EROSION_SEED + seed + o * 7919) & U32)
		hv += a * e[0]
		hx += a * f * e[1]
		hz += a * f * e[2]
		a *= 0.4
		f *= 2.0
	return hv


## uint32 multiply-xor-shift. Every step is masked back to 32 bits so this wraps the way C++ and GLSL do.
func _hash_u32(p_x: int) -> int:
	var x := p_x & U32
	x = (x ^ (x >> 16)) & U32
	x = (x * 0x7feb352d) & U32
	x = (x ^ (x >> 15)) & U32
	x = (x * 0x846ca68b) & U32
	x = (x ^ (x >> 16)) & U32
	return x


func _hash_cell(p_cx: int, p_cz: int, p_seed: int, p_salt: int) -> int:
	var h := _hash_u32((p_cx * 0x9e3779b1) & U32)
	h = _hash_u32(h ^ ((p_cz * 0x85ebca6b) & U32))
	h = _hash_u32(h ^ (p_seed & U32))
	return _hash_u32(h ^ p_salt)


## 24 bits into [0,1) — the float mantissa width, so this conversion is exact on the GPU too.
func _rnd01(p_h: int) -> float:
	return float(p_h & 0x00ffffff) / 16777216.0
