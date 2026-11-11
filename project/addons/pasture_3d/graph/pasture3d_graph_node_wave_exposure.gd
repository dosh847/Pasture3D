# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeWaveExposure — how much open water each cell faces (its FETCH), from a heightfield.
#
# The maths is in C++ (src/pasture_3d_wave_exposure.h, which also explains the one-sweep-per-direction
# recurrence). Water is every cell below `sea_level`. Land cells carry the exposure of the shore upwind of
# them `shore_reach` metres inland, so a cliff band several cells wide reads the exposure of its own shore.
#
# Typical use: Coast Profile -> Wave Exposure -> (Smooth) -> a second Coast Profile's `cliff` port, so
# exposed headlands get cliffs and sheltered coves get beaches.
@tool
class_name Pasture3DGraphNodeWaveExposure
extends Pasture3DGraphNode

## Height below which a cell is water, metres. Also a value port.
@export var sea_level: float = 0.0:
	set(v):
		sea_level = v
		_param_changed()
## Fetch at which exposure reads 1, metres. Longer open water than this counts the same.
@export_range(10.0, 50000.0, 10.0, "or_greater") var max_fetch: float = 3000.0:
	set(v):
		max_fetch = maxf(v, 1.0)
		_param_changed()
## How many directions are swept. A multiple of four keeps the axis directions exact.
@export_range(4, 64, 1) var directions: int = 16:
	set(v):
		directions = clampi(v, 1, 256)
		_param_changed()
## Compass bearing the prevailing wind blows FROM, degrees. 0 = north (-Z), 90 = east (+X).
@export_range(0.0, 360.0, 1.0) var wind_direction: float = 0.0:
	set(v):
		wind_direction = v
		_param_changed()
## 0 counts every direction equally; 1 counts only the upwind half, weighted toward the wind.
@export_range(0.0, 1.0, 0.01) var wind_strength: float = 0.0:
	set(v):
		wind_strength = clampf(v, 0.0, 1.0)
		_param_changed()
## How far inland a shore's exposure carries, metres, fading to zero. Set it to cover the cliff band.
@export_range(0.0, 500.0, 1.0, "or_greater") var shore_reach: float = 40.0:
	set(v):
		shore_reach = maxf(v, 0.0)
		_param_changed()
## Treat beyond the grid edge as open sea. Off, the edge is land and the border reads sheltered.
@export var edge_open: bool = true:
	set(v):
		edge_open = v
		_param_changed()


func op() -> StringName:
	return &"wave_exposure"


## The sixteen-slot block. The order is `wave_exposure_params_from`'s in src/pasture_3d_wave_exposure.cpp.
func native_lower() -> Dictionary:
	return {"params": _params()}


func _params() -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = sea_level
	p[1] = max_fetch
	p[2] = float(directions)
	p[3] = wind_direction
	p[4] = wind_strength
	p[5] = shore_reach
	p[6] = 1.0 if edge_open else 0.0
	return p


func native_out_count() -> int:
	return 2 # exposure, fetch


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


## Port 1 (`sea_level`) drives slot 0.
func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"height", PortType.HEIGHT).require(),
		Pasture3DGraphPort.value(&"sea_level", PortType.FLOAT, &"sea_level", 0),
	]


## Port order is a wire format: APPEND only.
func _outputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"exposure", PortType.MASK),
		Pasture3DGraphPort.field(&"fetch", PortType.FIELD),
	]


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	if not ClassDB.class_has_method("Pasture3DUtil", "wave_exposure_grid"):
		push_error("[Pasture3D] Pasture3DUtil.wave_exposure_grid is not bound. Rebuild GDExtension.")
		return _zero_fill(n)
	var h: PackedFloat32Array = p_inputs[0] if p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array \
			and p_inputs[0].size() == n else Pasture3DGraphOps.zeros(n)
	var prm := _params()
	# A wired sea level arrives as cell 0 of port 1 on this route (as the Leveler reads its value port); the
	# native route resolves it into P[0].
	if p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() > 0:
		prm[0] = float(p_inputs[1][0])
	var res: Dictionary = Pasture3DUtil.wave_exposure_grid(h, p_gw, p_gh, p_rect, prm)
	var e: PackedFloat32Array = res.get("exposure", PackedFloat32Array())
	if e.size() != n:
		push_error("[Pasture3D] wave_exposure_grid returned %d cells for a %d cell grid." % [e.size(), n])
		return _zero_fill(n)
	return [e, res["fetch"]]


## Zero exposure: the safe answer, which makes a downstream cliff port read "sheltered, beach".
func _zero_fill(p_n: int) -> Array:
	var z := PackedFloat32Array()
	z.resize(p_n)
	return [z, z.duplicate()]


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if directions % 4 != 0:
		out.append("Wave Exposure sweeps %d directions; a multiple of four keeps the axis directions exact." % directions)
	return out
