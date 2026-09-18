# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeStrata — a FILTER cell node: exposed rock layers. Like Terrace, but the benches are
# TILTED (geological dip) and broken up laterally, which is what makes sedimentary rock read as rock rather
# than a staircase. One input, one output; it bands EXACTLY the field wired into it and generates nothing.
#
# HEIGHT-DOMAIN, matching the Terrace node: a bench every `band_height` metres, with the band boundaries
# tilted by `dip` (metres of rise per 100 m along the dip direction) and wandered by world-space noise.
@tool
class_name Pasture3DGraphNodeStrata
extends Pasture3DGraphNode

## Elevation between rock layers, in metres.
@export_range(0.5, 200.0, 0.1, "or_greater") var band_height: float = 8.0:
	set(v):
		band_height = maxf(v, 0.001)
		emit_changed()

## Strata frequency (layers per 100m). Convenience view of layer density.
var strata_frequency: float:
	get:
		return 100.0 / maxf(band_height, 0.001)
	set(v):
		if v > 0.0:
			band_height = 100.0 / v

## Bench shape. SHARP: a steep riser at the foot of each bed, then a gentle tread (two straight segments).
## SMOOTH: the same idea as a continuous curve. A Terrace Profile curve, when assigned, overrides both.
enum Profile { SHARP, SMOOTH }

## Layer resistance / hardness contrast. 0 leaves the field untouched; 1 gives a strong ledge at the foot of
## every bed. Maps to the profile gamma as 1 - 0.85 * hardness.
@export_range(0.0, 1.0, 0.01) var hardness: float = 0.75:
	set(v):
		hardness = clampf(v, 0.0, 1.0)
		emit_changed()

## Bench shape; ignored while a Terrace Profile curve is assigned.
@export var profile: Profile = Profile.SHARP:
	set(v):
		profile = v
		emit_changed()

## How much hardness wanders across the ground, so some beds ledge and others weather soft. Driven by the same
## noise as Break Up (its size is Break Size, its pattern the seed).
@export_range(0.0, 1.0, 0.01) var hardness_variation: float = 0.5:
	set(v):
		hardness_variation = clampf(v, 0.0, 1.0)
		emit_changed()

## Beds inside beds: each octave re-bands the previous one at Band Height / Lacunarity^k. 1 = a single set.
@export_range(1, 8, 1) var octaves: int = 3:
	set(v):
		octaves = clampi(v, 1, 8)
		emit_changed()

## How much thinner each octave's beds are than the last.
@export_range(1.0, 4.0, 0.05) var lacunarity: float = 2.0:
	set(v):
		lacunarity = maxf(v, 1.0)
		emit_changed()

## Hardness contrast alias for geological parameter naming.
var hardness_contrast: float:
	get:
		return hardness
	set(v):
		hardness = v

## Cross-fade between the input (0) and the fully-layered field (1).
@export_range(0.0, 1.0, 0.01) var amount: float = 1.0:
	set(v):
		amount = clampf(v, 0.0, 1.0)
		emit_changed()

## Optional custom cross-section profile for strata ledges. When null, uses the Profile setting.
@export var terrace_profile: Curve:
	set(v):
		if terrace_profile != null and terrace_profile.changed.is_connected(emit_changed):
			terrace_profile.changed.disconnect(emit_changed)
		terrace_profile = v
		if terrace_profile != null and not terrace_profile.changed.is_connected(emit_changed):
			terrace_profile.changed.connect(emit_changed)
		emit_changed()

@export_group("Dip & Strike")
## Geological dip: how far the layers tilt across the ground, in METRES of rise per 100 m. 0 = horizontal bedding.
@export_range(-45.0, 45.0, 0.1) var dip: float = 4.0:
	set(v):
		dip = v
		emit_changed()

## Geological dip angle alias in degrees (tan(dip_angle) * 100 = dip).
var dip_angle: float:
	get:
		return rad_to_deg(atan(dip * 0.01))
	set(v):
		dip = tan(deg_to_rad(v)) * 100.0

## Compass direction the layers dip towards, in degrees.
@export_range(0.0, 360.0, 1.0) var dip_direction_degrees: float = 45.0:
	set(v):
		dip_direction_degrees = v
		emit_changed()

## Strike direction azimuth alias (perpendicular to dip direction).
var strike_direction: float:
	get:
		return fposmod(dip_direction_degrees + 90.0, 360.0)
	set(v):
		dip_direction_degrees = fposmod(v - 90.0, 360.0)

@export_group("Break Up")
## How far the layer boundaries wander, in metres, so beds break into local plates rather than running dead straight.
@export_range(0.0, 32.0, 0.1, "or_greater") var break_amount: float = 3.0:
	set(v):
		break_amount = maxf(v, 0.0)
		_dirty = true
		emit_changed()

## Size of those plates, in metres.
@export_range(4.0, 512.0, 1.0, "or_greater") var break_size: float = 45.0:
	set(v):
		break_size = maxf(v, 0.01)
		_dirty = true
		emit_changed()

@export var seed: int = 0:
	set(v):
		seed = v
		_dirty = true
		emit_changed()

@export_group("Where Strata Show")
## Fade the strata in by the INPUT height: none at or below Mask Low, full at or above Mask High, so beds
## stand out on high ground and valleys stay smooth. Metres, not the grid's own range: an auto range would
## move whenever the solved extent did (a Modifier Margin brings surrounding ground into it).
@export var elevation_mask: bool = true:
	set(v):
		elevation_mask = v
		emit_changed()

## Height, in metres, below which no strata show.
@export_range(-500.0, 2000.0, 0.5, "or_less", "or_greater", "suffix:m") var mask_low: float = 0.0:
	set(v):
		mask_low = v
		emit_changed()

## Height, in metres, above which the strata show in full.
@export_range(-500.0, 2000.0, 0.5, "or_less", "or_greater", "suffix:m") var mask_high: float = 100.0:
	set(v):
		mask_high = v
		emit_changed()

## Break the strata into elongated outcrops: along the borders of long cells turned 45 degrees off the dip,
## the beds show in full; inside the cells they fade by this much. 0 = an even skin of strata.
@export_range(0.0, 1.0, 0.01) var outcrop_strength: float = 0.4:
	set(v):
		outcrop_strength = clampf(v, 0.0, 1.0)
		emit_changed()

## Length of the outcrop cells along their long axis, in metres (they are a third as wide).
@export_range(10.0, 2000.0, 1.0, "or_greater", "suffix:m") var outcrop_size: float = 180.0:
	set(v):
		outcrop_size = maxf(v, 0.01)
		emit_changed()

const _U32 := 0xffffffff
const _FLAG_ELEVATION_MASK := 2

var _break: FastNoiseLite = null
var _dirty := true


func op() -> StringName:
	return &"strata"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	# `wavelength` and `dip_direction_deg` are not properties of the node (they are `band_height`
	# and `dip_direction_degrees`), and the surviving values sat in the wrong argument slots.
	p[0] = band_height
	p[1] = hardness
	p[2] = amount
	p[3] = dip
	p[4] = dip_direction_degrees
	p[5] = break_amount
	p[6] = break_size
	p[7] = float(seed)
	p[8] = float(int(profile) | (_FLAG_ELEVATION_MASK if elevation_mask else 0))
	p[9] = hardness_variation
	p[10] = float(octaves)
	p[11] = lacunarity
	p[12] = mask_low
	p[13] = mask_high
	p[14] = outcrop_strength
	p[15] = outcrop_size
	return {"params": p, "lut": profile_lut()}


## The terrace profile as 256 samples over [0, 1], or empty for the built-in profile. It was never lowered
## before spec Phase 2b, so the native and GPU routes ignored a custom profile that eval_cell honoured.
func profile_lut() -> PackedFloat32Array:
	var lut := PackedFloat32Array()
	if terrace_profile != null:
		lut.resize(256)
		for i in 256:
			lut[i] = terrace_profile.sample_baked(float(i) / 255.0)
	return lut


func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1, 0, 1, 3, 4, 2])


func role() -> Role:
	return Role.FILTER


func input_count() -> int:
	return 6


func input_names() -> PackedStringArray:
	return PackedStringArray(["in", "band_height", "hardness", "dip", "direction", "amount"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.HEIGHT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.FLOAT,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return 0.0
		1: return band_height
		2: return hardness
		3: return dip
		4: return dip_direction_degrees
		5: return amount
		_: return 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var s: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array) else Pasture3DGraphOps.zeros(p_gw * p_gh)
	var bh: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else band_height
	var h: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else hardness
	var d: float = float(p_inputs[3][0]) if (p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0) else dip
	var dir: float = float(p_inputs[4][0]) if (p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array and p_inputs[4].size() > 0) else dip_direction_degrees
	var amt: float = float(p_inputs[5][0]) if (p_inputs.size() > 5 and p_inputs[5] is PackedFloat32Array and p_inputs[5].size() > 0) else amount

	# The profile goes to native as its LUT, the same table the compiled program carries. eval_cell stays the
	# exact-curve oracle.
	return Pasture3DUtil.strata_grid(s, p_gw, p_gh, p_rect, bh, h, amt, d, dir, break_amount, break_size, seed,
			profile_lut(), int(profile) | (_FLAG_ELEVATION_MASK if elevation_mask else 0), hardness_variation,
			octaves, lacunarity, mask_low, mask_high, outcrop_strength, outcrop_size)


func eval_cell(p_wx: float, p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var x: float = p_inputs[0] if (p_inputs.size() > 0 and not is_nan(p_inputs[0])) else 0.0
	var bh: float = p_inputs[1] if (p_inputs.size() > 1 and not is_nan(p_inputs[1])) else band_height
	var h: float = p_inputs[2] if (p_inputs.size() > 2 and not is_nan(p_inputs[2])) else hardness
	var d: float = p_inputs[3] if (p_inputs.size() > 3 and not is_nan(p_inputs[3])) else dip
	var dir: float = p_inputs[4] if (p_inputs.size() > 4 and not is_nan(p_inputs[4])) else dip_direction_degrees
	var amt: float = p_inputs[5] if (p_inputs.size() > 5 and not is_nan(p_inputs[5])) else amount

	if is_nan(x):
		return x

	var dipdir := deg_to_rad(dir)
	var dip_tilt := d * (p_wx * cos(dipdir) + p_wz * sin(dipdir)) * 0.01
	var g := hardness_to_gamma(h)
	var nv := 0.0
	if break_amount > 0.0 or hardness_variation > 0.0:
		nv = _break_field().get_noise_2d(p_wx, p_wz)
		g = local_gamma(g, hardness_variation, nv)
	var bh_clean := maxf(bh, 0.001)
	var lac := maxf(lacunarity, 1.0)

	# Octave k bands octave k-1's output at band_height / lacunarity^k; the break wander shrinks with the bed.
	var val := x
	var scale := 1.0
	for k in clampi(octaves, 1, 8):
		var bh_k := bh_clean / scale
		var tilt := dip_tilt + nv * break_amount / scale
		var t := (val + tilt) / bh_k
		var q := floorf(t)
		var f := t - q
		var profile_val: float
		if terrace_profile != null:
			profile_val = terrace_profile.sample_baked(clampf(f, 0.0, 1.0))
		else:
			profile_val = profile_value(int(profile), f, g)
		# The tilt only chooses where the beds fall; it comes back off, or the dip would tilt the ground itself.
		val = (q + profile_val) * bh_k - tilt
		scale *= lac
	# Where the strata show: the elevation window on the input height, then the outcrop cells.
	var t := amt
	if elevation_mask:
		t *= elevation_factor(x, mask_low, mask_high)
	t *= outcrop_factor(p_wx, p_wz, cos(dipdir), sin(dipdir), nv, outcrop_size, outcrop_strength, seed)
	return x + (val - x) * t


## 0 at or below p_lo, 1 at or above p_hi, linear between. Twin of strata_elevation_mask.
static func elevation_factor(p_x: float, p_lo: float, p_hi: float) -> float:
	if p_hi <= p_lo:
		return 1.0 if p_x >= p_lo else 0.0
	return clampf((p_x - p_lo) / (p_hi - p_lo), 0.0, 1.0)


## The outcrop factor in [1 - strength, 1]. Twin of strata_outcrop (src/pasture_3d_strata.h), which the GPU
## route also fills its buffer with; the hash is integer and masked to 32 bits so all three agree exactly.
static func outcrop_factor(p_wx: float, p_wz: float, p_cos: float, p_sin: float, p_nv: float,
		p_size: float, p_strength: float, p_seed: int) -> float:
	if p_strength <= 0.0:
		return 1.0
	var size := maxf(p_size, 0.01)
	var k := 0.70710678118654752
	var lc := (p_cos - p_sin) * k
	var ls := (p_sin + p_cos) * k
	var u := (p_wx * lc + p_wz * ls) / size + 0.4 * p_nv
	var v := (p_wx * p_cos + p_wz * p_sin) / (size / 3.0)
	var cu := floori(u)
	var cv := floori(v)
	var f1 := 1.0e30
	var f2 := 1.0e30
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var cx := cu + dx
			var cz := cv + dz
			var fx := float(cx) + float(_hash_cell(cx, cz, p_seed, 0x51) & 0x00ffffff) / 16777216.0
			var fz := float(cz) + float(_hash_cell(cx, cz, p_seed, 0x52) & 0x00ffffff) / 16777216.0
			var d := sqrt((u - fx) * (u - fx) + (v - fz) * (v - fz))
			if d < f1:
				f2 = f1
				f1 = d
			elif d < f2:
				f2 = d
	return 1.0 - clampf(p_strength, 0.0, 1.0) * clampf(f2 - f1, 0.0, 1.0)


static func _hash_u32(p_x: int) -> int:
	var x := p_x & _U32
	x = (x ^ (x >> 16)) & _U32
	x = (x * 0x7feb352d) & _U32
	x = (x ^ (x >> 15)) & _U32
	x = (x * 0x846ca68b) & _U32
	x = (x ^ (x >> 16)) & _U32
	return x


static func _hash_cell(p_cx: int, p_cz: int, p_seed: int, p_salt: int) -> int:
	var h := _hash_u32((p_cx * 0x9e3779b1) & _U32)
	h = _hash_u32(h ^ ((p_cz * 0x85ebca6b) & _U32))
	h = _hash_u32(h ^ (p_seed & _U32))
	return _hash_u32(h ^ p_salt)


## Hardness [0, 1] to the profile gamma: 0 = identity, 1 = a strong ledge. Twin of strata_hardness_to_gamma.
static func hardness_to_gamma(p_hardness: float) -> float:
	return lerpf(1.0, 0.15, clampf(p_hardness, 0.0, 1.0))


## The gamma under lateral hardness variation, n = the break noise in [-1, 1]. A power, so hardness 0 (gamma 1)
## stays the identity. Twin of strata_local_gamma.
static func local_gamma(p_gamma: float, p_variation: float, p_n: float) -> float:
	return clampf(pow(p_gamma, 1.0 + p_variation * p_n), 0.05, 10.0)


## The bench profile over one bed, [0, 1] onto [0, 1]. Twin of strata_profile (C++) and GKM_STRATA (GLSL).
static func profile_value(p_mode: int, p_u: float, p_g: float) -> float:
	var u := clampf(p_u, 0.0, 1.0)
	if p_mode == Profile.SMOOTH:
		return pow(u, p_g) * (1.0 - exp(-(50.0 / p_g) * u))
	if absf(p_g - 1.0) < 1.0e-3:
		return u
	var a := pow(1.0 / p_g, 1.0 / (p_g - 1.0))
	var b := pow(p_g, -p_g / (p_g - 1.0))
	return u * b / a if u < a else b + (1.0 - b) * (u - a) / (1.0 - a)


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amount):
		w.append("%s: Amount is 0, so it passes the input through unchanged." % display_name())
	elif hardness <= 0.0 and terrace_profile == null:
		w.append("%s: Hardness is 0, so the beds have no visible risers." % display_name())
	return w


func _break_field() -> FastNoiseLite:
	if _dirty or _break == null:
		_break = FastNoiseLite.new()
		_break.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_break.fractal_type = FastNoiseLite.FRACTAL_FBM
		_break.fractal_octaves = 3
		_break.frequency = 1.0 / maxf(break_size, 0.01)
		_break.seed = seed
		_dirty = false
	return _break
