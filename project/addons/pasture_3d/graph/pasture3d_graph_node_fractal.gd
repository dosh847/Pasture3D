# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeFractal — a GENERATOR grid node: the relief FRACTAL material, in the graph.
#
# This is the workhorse "make this craggy" field — rolling hills (fBm), craggy rock (ridged multifractal)
# or lumpy dunes (billow), with the optional domain warp that breaks up the regularity plain fBm always
# has. It is the clean-category counterpart of Pasture3DReliefFractal, exactly as the Dunes and Furrows
# nodes are of the relief DUNES and FURROWS ops: the same shaping controls and the same arithmetic, with
# none of the material's accumulator / selector / blend wrapper.
#
# ---- WHY THIS IS NOT THE EXISTING NOISE NODE ----
#
# Pasture3DGraphNodeNoise scales somebody else's FastNoiseLite. That covers fBm, because FastNoiseLite has
# an fBm mode — it does NOT cover the two things this material is actually reached for. There is no
# `sharpness` on a FastNoiseLite ridge (the signed power that turns ridges into knife edges is applied to
# the noise's OUTPUT here, after the fractal sum), and there is no standalone domain warp: Godot's
# FastNoiseLite applies its `domain_warp_*` settings internally to get_noise_2d and exposes no call to read
# the offset, which is why the relief evaluator computes the displacement explicitly and why this does too.
#
# ---- AMPLITUDE IS METRES ----
#
# The material's `amplitude` is a FRACTION of the host brush's Height Scale, because a relief material is
# always inside a brush that owns the scale. A graph generator has no host to take a scale from, so the
# same property here is METRES at the noise's full ±1 output — the convention every other graph generator
# uses (see Dunes, "crest-to-trough height at full output, in METRES"). The two agree numerically whenever
# the brush's Height Scale is 1.
@tool
class_name Pasture3DGraphNodeFractal
extends Pasture3DGraphNode

const ReliefMaterial = preload("res://addons/pasture_3d/connectors/pasture3d_relief_material.gd")

## HILLS = smooth rolling fBm. CRAGGY = ridged multifractal (sharp ridges, smooth valleys — the classic
## rocky look). LUMPY = billow (rounded mounds, good under dunes and moraine).
## The ids are a WIRE FORMAT shared with Pasture3DReliefFractal.Style and the native FractalStyle enum.
enum Style { HILLS, CRAGGY, LUMPY }

@export var style: Style = Style.CRAGGY:
	set(v):
		style = v
		notify_property_list_changed() # sharpness is CRAGGY-only, and a hint is invisible without this
		_dirty = true
		emit_changed()
## Metres of relief at the fractal's full ±1 output.
@export_range(0.0, 200.0, 0.01, "or_greater") var amplitude: float = 20.0:
	set(v):
		amplitude = v
		emit_changed()
## Size of the largest feature, in metres. Smaller = busier relief. (Frequency is 1 / feature size.)
@export_range(1.0, 2048.0, 0.5, "or_greater") var feature_size: float = 256.0:
	set(v):
		feature_size = maxf(v, 0.01)
		_dirty = true
		emit_changed()
## Detail levels stacked on top of the base feature. Each octave divides the size by Lacunarity and
## multiplies the height by Gain. Beyond ~5 the extra octaves fall below the terrain's vertex spacing and
## only cost time.
@export_range(1, 8) var octaves: int = 5:
	set(v):
		octaves = clampi(v, 1, 8)
		_dirty = true
		emit_changed()
## Size ratio between octaves. 2.0 = each octave is half the size of the one before.
@export_range(1.5, 4.0, 0.01) var lacunarity: float = 2.0:
	set(v):
		lacunarity = v
		_dirty = true
		emit_changed()
## Height ratio between octaves. Higher = rougher; lower = smoother, more dominated by the base shape.
@export_range(0.1, 0.9, 0.01) var gain: float = 0.5:
	set(v):
		gain = v
		_dirty = true
		emit_changed()
## CRAGGY only. Above 1 sharpens ridges into knife edges; below 1 rounds them off.
@export_range(0.25, 4.0, 0.01) var sharpness: float = 1.0:
	set(v):
		sharpness = v
		emit_changed()
@export var seed: int = 0:
	set(v):
		seed = v
		_dirty = true
		emit_changed()

@export_group("Domain Warp")
## Metres of lateral displacement applied to the sample point before the fractal is read. This is what
## turns regular-looking noise into twisted, tectonic-looking relief. 0 = off (no cost, no noise built).
@export_range(0.0, 256.0, 0.5, "or_greater") var warp_amount: float = 0.0:
	set(v):
		warp_amount = maxf(v, 0.0)
		_dirty = true
		emit_changed()
## Size of the warping swirls, in metres. Usually a bit larger than Feature Size.
@export_range(1.0, 2048.0, 0.5, "or_greater") var warp_size: float = 384.0:
	set(v):
		warp_size = maxf(v, 0.01)
		_dirty = true
		emit_changed()
@export_range(1, 4) var warp_octaves: int = 2:
	set(v):
		warp_octaves = clampi(v, 1, 4)
		_dirty = true
		emit_changed()

# The noise instances, rebuilt only when a shaping property changes — the same construction the relief
# evaluator's _make_noise performs, so the two read the same field. `_warp` is empty when warp_amount is 0.
var _noise: FastNoiseLite = null
var _warp: Array = []
var _dirty := true


## Chaining is not optional — the base wires `changed` into the graph revision, and a subclass `_init`
## that does not call it drops that wiring silently.
func _init() -> void:
	super()


func _validate_property(property: Dictionary) -> void:
	if property.name == "sharpness" and style != Style.CRAGGY:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func op() -> StringName:
	return &"fractal"


## Param layout, mirrored by the GRAPH_OP_FRACTAL case in src/pasture_3d_graph_ops.cpp. The four
## PORT-DRIVEN slots come first so native_param_ports() is the identity on them.
func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = amplitude
	p[1] = feature_size
	p[2] = sharpness
	p[3] = warp_amount
	p[4] = float(style)
	p[5] = float(octaves)
	p[6] = lacunarity
	p[7] = gain
	p[8] = float(seed)
	p[9] = warp_size
	p[10] = float(warp_octaves)
	return {"params": p}


func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([0, 1, 2, 3])


func role() -> Role:
	return Role.GENERATOR


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["amplitude", "feature_size", "sharpness", "warp_amount"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.FLOAT,
		PortType.FLOAT,
	])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		0: return amplitude
		1: return feature_size
		2: return sharpness
		3: return warp_amount
		_: return 0.0


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> PackedFloat32Array:
	var a := _wired(p_inputs, 0, amplitude)
	var fs := _wired(p_inputs, 1, feature_size)
	var sh := _wired(p_inputs, 2, sharpness)
	var wa := _wired(p_inputs, 3, warp_amount)
	return Pasture3DUtil.fractal_grid(p_gw, p_gh, p_rect, int(style), a, fs, octaves,
			lacunarity, gain, sh, seed, wa, warp_size, warp_octaves)


## The per-cell route, and the oracle the kernel above is held to: it walks the SAME FastNoiseLite
## construction the relief evaluator uses, through the same `_configure_noise`.
##
## `feature_size` and `warp_amount` are read from the node here, not from their ports: the noise is built
## once and cached, so a per-cell frequency would mean rebuilding a FastNoiseLite per cell. Wiring those
## two ports is a grid-route facility (eval_grid rebuilds once for the whole grid) — a Const driving them
## through a cell run would be ignored, which node_warnings says out loud.
func eval_cell(p_wx: float, p_wz: float, p_inputs: PackedFloat32Array) -> float:
	var a: float = p_inputs[0] if (p_inputs.size() > 0 and not is_nan(p_inputs[0])) else amplitude
	var sh: float = p_inputs[2] if (p_inputs.size() > 2 and not is_nan(p_inputs[2])) else sharpness

	var u := p_wx
	var v := p_wz
	if warp_amount > 0.0:
		var pair := _warp_noise()
		# Both offsets read at the UNDISPLACED point, then applied together — the relief WARP op.
		var du: float = pair[0].get_noise_2d(u, v) * warp_amount
		var dv: float = pair[1].get_noise_2d(u, v) * warp_amount
		u += du
		v += dv

	var raw: float = _fractal_noise().get_noise_2d(u, v)
	if style == Style.LUMPY:
		raw = absf(raw) * 2.0 - 1.0
	elif style == Style.CRAGGY and sh != 1.0 and sh > 0.0:
		raw = signf(raw) * pow(absf(raw), sh)
	return raw * a


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if is_zero_approx(amplitude):
		w.append("%s: Amplitude is 0 m, so the fractal contributes nothing." % display_name())
	elif style != Style.CRAGGY and not is_equal_approx(sharpness, 1.0):
		w.append("%s: Sharpness only shapes the CRAGGY style and is ignored here." % display_name())
	return w


# ---- Internals -------------------------------------------------------------------------------------

func _wired(p_inputs: Array, p_port: int, p_fallback: float) -> float:
	if p_inputs.size() > p_port and p_inputs[p_port] is PackedFloat32Array and p_inputs[p_port].size() > 0:
		return float(p_inputs[p_port][0])
	return p_fallback


func _fractal_noise() -> FastNoiseLite:
	_rebuild()
	return _noise


func _warp_noise() -> Array:
	_rebuild()
	return _warp


func _rebuild() -> void:
	if not _dirty and _noise != null:
		return
	_noise = ReliefMaterial._configure_noise(1.0 / maxf(feature_size, 0.01), octaves, lacunarity,
			gain, seed, style == Style.CRAGGY)
	if warp_amount > 0.0:
		# The seed offsets are Pasture3DReliefFractal._build's (+7717 on the WARP op it emits) and
		# _make_noise's (+1013 on the second of the pair). They are what makes this node and that
		# material read the same field.
		var ws := seed + 7717
		var wf := 1.0 / maxf(warp_size, 0.01)
		_warp = [
			ReliefMaterial._configure_noise(wf, warp_octaves, 2.0, 0.5, ws, false),
			ReliefMaterial._configure_noise(wf, warp_octaves, 2.0, 0.5, ws + 1013, false),
		]
	else:
		_warp = []
	_dirty = false
