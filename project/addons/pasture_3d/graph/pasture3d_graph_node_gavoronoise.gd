# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeGavoronoise — eroded-terrain noise: a smooth Gabor-wave landform with branching gullies
# cut down its slopes. Hesiod's Gavoronoise, after Clay John's "Eroded Terrain Noise" (MIT); the algorithm
# and both MIT notices are in src/pasture_3d_gavoronoise.h.
#
# Two forms:
#   GENERATOR  `base` unwired. The node makes its own landform from oriented Gabor waves (`frequency`,
#              `angle`, `angle_spread`) and erodes it. Output is 0..`amplitude` metres, roughly.
#   BASE INPUT `base` wired. The node erodes THAT surface along its own slope and returns it with the
#              gullies cut in. This is the one for dissecting an existing hill: wire the hill in, take the
#              output as the hill. Do not add it back on top — the input is already in it.
#
# The gullies run DOWNHILL because each wave's crests are laid along the contour-normal of the slope it
# sits on, and every erosion octave's own slope turns the next octave's gullies, which is the branching.
# Erosion fades in with height (`z_cut_min`..`z_cut_max`, as fractions of `amplitude`), so valleys stay
# smooth and high ground is cut hardest.
@tool
class_name Pasture3DGraphNodeGavoronoise
extends Pasture3DGraphNode

## Height in WORLD METRES. The generator's output spans about 0..amplitude. With `base` wired it is the
## height scale the base is read at: set it to the height of the landform being eroded, so the z-cut window
## and the gully depth are fractions of that landform.
@export_range(0.0, 2000.0, 1.0, "or_greater", "suffix:m") var amplitude: float = 60.0:
	set(v):
		amplitude = v
		emit_changed()

## CYCLES PER METRE of the base landform. 0.002 is a feature roughly every 500 m. Per metre, not per cell,
## so the same world rect gives the same spacing at any bake resolution.
@export_range(0.0001, 0.05, 0.0001, "or_greater") var frequency: float = 0.002:
	set(v):
		frequency = maxf(v, 0.00001)
		emit_changed()

## Erosion octaves. Each one cuts gullies twice as fine, branching off the last.
@export_range(1, 12, 1) var octaves: int = 8:
	set(v):
		octaves = clampi(v, 1, 12)
		emit_changed()

@export var seed: int = 0:
	set(v):
		seed = v
		emit_changed()

@export_group("Erosion")

## Gully depth, as a fraction of `amplitude`. 0.05 is gentle; 0.1-0.2 is deeply dissected.
@export_range(0.0, 1.0, 0.005, "or_greater") var erosion_strength: float = 0.1:
	set(v):
		erosion_strength = maxf(v, 0.0)
		emit_changed()

## How many erosion cells fit in one base cell. Higher packs the gullies closer together.
@export_range(0.5, 16.0, 0.1, "or_greater") var erosion_frequency: float = 4.0:
	set(v):
		erosion_frequency = maxf(v, 0.01)
		emit_changed()

## How strongly the slope sets the gully spacing. Steeper ground and a higher value give tighter gullies;
## flat ground gets none.
@export_range(0.0, 10.0, 0.05, "or_greater") var slope_strength: float = 1.0:
	set(v):
		slope_strength = maxf(v, 0.0)
		emit_changed()

## How far each erosion octave's own slope turns the next octave's gullies. This IS the branching: at 0
## every octave runs straight down the base slope and the gullies are parallel.
@export_range(0.0, 10.0, 0.05) var branch_strength: float = 2.0:
	set(v):
		branch_strength = maxf(v, 0.0)
		emit_changed()

## Erosion is absent below this height and fades in up to `z_cut_max`, both as fractions of `amplitude`.
@export_range(0.0, 1.0, 0.01) var z_cut_min: float = 0.2:
	set(v):
		z_cut_min = clampf(v, 0.0, 1.0)
		emit_changed()

## Erosion is at full strength from this height up, as a fraction of `amplitude`.
@export_range(0.0, 1.0, 0.01) var z_cut_max: float = 1.0:
	set(v):
		z_cut_max = clampf(v, 0.0, 1.0)
		emit_changed()

@export_group("Base")

## GENERATOR only: the direction the base landform's ridges run along, in degrees.
@export_range(0.0, 360.0, 1.0) var angle_deg: float = 0.0:
	set(v):
		angle_deg = v
		emit_changed()

## GENERATOR only: how far the base ridges wander off `angle`. 0 is parallel ridges; 1 hides the angle.
@export_range(0.0, 1.0, 0.01) var angle_spread: float = 1.0:
	set(v):
		angle_spread = clampf(v, 0.0, 1.0)
		emit_changed()

## BASE INPUT only: how far the input is smoothed before its slope is read, in WORLD METRES. 0 follows every
## bump; larger follows only the big shape. The height itself is never smoothed.
@export_range(0.0, 1000.0, 1.0, "or_greater", "suffix:m") var base_smoothing: float = 0.0:
	set(v):
		base_smoothing = maxf(v, 0.0)
		emit_changed()


func op() -> StringName:
	return &"gavoronoise"


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = amplitude
	p[1] = frequency
	p[2] = float(octaves)
	p[3] = float(seed)
	p[4] = angle_deg
	p[5] = angle_spread
	p[6] = slope_strength
	p[7] = branch_strength
	p[9] = z_cut_min
	p[10] = z_cut_max
	p[11] = base_smoothing
	p[12] = erosion_strength
	p[13] = erosion_frequency
	return {"params": p}


func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([0, 4, 1, -1])


func role() -> Role:
	return Role.GENERATOR


## TRUE, where the spec proposed false: there is no `eval_cell` the fold could inline — the octave loops
## are not a per-cell expression a neighbour's loop can absorb.
func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["amplitude", "angle", "frequency", "base"])


## Port 3 is the only grid this node reads; it rides in3.
func aux_grid_port() -> int:
	return 3 # "base"


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.FLOAT, PortType.FLOAT, PortType.FLOAT, PortType.HEIGHT])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return amplitude
		1: return angle_deg
		2: return frequency
		# NAN, because the GDScript evaluators hand an unwired port to eval_grid as a grid FILLED with this,
		# and a filled grid of 0 is a perfectly good flat base. All-NaN is the only way back to "unwired".
		3: return NAN
		_: return 0.0


## The kernel's parameters as the Dictionary Pasture3DUtil takes. Gates and the oracle use it too.
func kernel_params(p_amp: float, p_angle: float, p_freq: float) -> Dictionary:
	return {"amplitude": p_amp, "frequency": p_freq, "octaves": octaves, "seed": seed, "angle_deg": p_angle,
			"angle_spread": angle_spread, "slope_strength": slope_strength, "branch_strength": branch_strength,
			"z_cut_min": z_cut_min, "z_cut_max": z_cut_max, "erosion_strength": erosion_strength,
			"erosion_frequency": erosion_frequency}


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var n := p_gw * p_gh
	var amp: float = float(p_inputs[0][0]) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and p_inputs[0].size() > 0) else amplitude
	var ang: float = float(p_inputs[1][0]) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0) else angle_deg
	var freq: float = float(p_inputs[2][0]) if (p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array and p_inputs[2].size() > 0) else frequency

	if not ClassDB.class_has_method("Pasture3DUtil", "gavoronoise_base_grid"):
		push_error("[Pasture3D] Pasture3DUtil.gavoronoise_base_grid is not bound. Rebuild GDExtension.")
		return Pasture3DGraphOps.zeros(n)

	var kp := kernel_params(amp, ang, freq)
	var res: PackedFloat32Array
	if _base_is_wired(p_inputs, n):
		res = Pasture3DUtil.gavoronoise_base_grid(p_gw, p_gh, p_rect, kp, p_inputs[3], base_smoothing)
	else:
		res = Pasture3DUtil.gavoronoise_grid(p_gw, p_gh, p_rect, kp)
	if res.size() != n:
		push_error("[Pasture3D] Gavoronoise returned an invalid grid size.")
		return Pasture3DGraphOps.zeros(n)
	return res


## A wired base is a grid of the right size that is not entirely NaN (see input_unwired_default). A wired
## surface that is ALL holes reads as unwired here, where the native route would return it unchanged; there
## is no terrain in it either way.
func _base_is_wired(p_inputs: Array, p_n: int) -> bool:
	if p_inputs.size() <= 3 or not (p_inputs[3] is PackedFloat32Array):
		return false
	var b: PackedFloat32Array = p_inputs[3]
	if b.size() != p_n:
		return false
	for v in b:
		if not is_nan(v):
			return true
	return false


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(erosion_strength):
		w.append("%s: Erosion Strength is 0, so there are no gullies — only the Gabor base (or the input, unchanged)." % display_name())
	if z_cut_max <= z_cut_min:
		w.append("%s: Z Cut Max is not above Z Cut Min, so erosion switches on as a hard step at Z Cut Max." % display_name())
	if is_zero_approx(amplitude):
		w.append("%s: Amplitude is 0, so the output is flat (or the input, unchanged)." % display_name())
	return w
