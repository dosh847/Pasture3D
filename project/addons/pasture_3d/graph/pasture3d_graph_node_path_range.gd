# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathRange — a crest line turned into a mountain range: peaks that vary along the crest,
# spurs raking off both sides, valleys forming between them. PASTURE3D_RANGES_SPEC.md step 1; the model is
# in src/pasture_3d_path_range.h and the maths is C++ only.
#
# Wiring: a Spline Source (a hand-drawn crest) or, later, Generate Range Splines into `path`; the island
# height into `height` so the range sits on it (ADD) or rises out of it (MAX); a mask into `amount` to fade
# the range, e.g. toward the coast. Erode the result (Salève, Stream Log) to cut drainage into the spurs.
# Texture is not built in: add a Fractal (any style) multiplied by `footprint`, or by `height` for rock
# that scales with the range, after this node.
# Port 0 is a PATH, so the framework adds no standard mask.
@tool
class_name Pasture3DGraphNodePathRange
extends Pasture3DGraphNode

enum CrestShape { ROUND, SHARP, FLAT }
enum BlendMode { ADD, MAX }

@export_group("Crest")
## Crest height at the middle of the range, metres. Also a value port.
@export_range(0.0, 3000.0, 1.0, "or_greater") var peak_height: float = 300.0:
	set(v):
		peak_height = maxf(v, 0.0)
		_param_changed()
## Distance between high points along the crest, metres.
@export_range(1.0, 5000.0, 1.0, "or_greater") var peak_spacing: float = 600.0:
	set(v):
		peak_spacing = maxf(v, 1.0)
		_param_changed()
## How much peak heights vary along the crest. 0 = an even crest.
@export_range(0.0, 2.0, 0.01) var peak_variation: float = 0.5:
	set(v):
		peak_variation = clampf(v, 0.0, 2.0)
		_param_changed()
## Distance over which an open crest falls at each end, metres.
@export_range(0.0, 5000.0, 1.0, "or_greater") var end_taper: float = 400.0:
	set(v):
		end_taper = maxf(v, 0.0)
		_param_changed()
## Height at the very ends, as a fraction of the crest.
@export_range(0.0, 1.0, 0.01) var end_height: float = 0.2:
	set(v):
		end_height = clampf(v, 0.0, 1.0)
		_param_changed()
## Half-width per metre of height. Higher = gentler flanks; the same steepness at every size.
@export_range(0.05, 10.0, 0.05, "or_greater") var width_ratio: float = 2.5:
	set(v):
		width_ratio = maxf(v, 0.05)
		_param_changed()
## Cross-section of every ridge line.
@export var crest_shape: CrestShape = CrestShape.ROUND:
	set(v):
		crest_shape = v
		_param_changed()
## Use the path's own heights (a draped or hand-set spline) as the crest height instead of Peak Height.
@export var use_path_heights: bool = false:
	set(v):
		use_path_heights = v
		_param_changed()

@export_group("Spurs")
## Distance between spurs along the crest, metres. They alternate sides.
@export_range(1.0, 5000.0, 1.0, "or_greater") var spur_spacing: float = 250.0:
	set(v):
		spur_spacing = maxf(v, 1.0)
		_param_changed()
## Length of a spur under a full-height crest, metres. 0 = no spurs.
@export_range(0.0, 5000.0, 1.0, "or_greater") var spur_length: float = 500.0:
	set(v):
		spur_length = maxf(v, 0.0)
		_param_changed()
## Degrees a spur rakes back from square to the crest.
@export_range(-80.0, 80.0, 0.5) var spur_angle: float = 25.0:
	set(v):
		spur_angle = clampf(v, -80.0, 80.0)
		_param_changed()
## Random spread of the spur angle, degrees.
@export_range(0.0, 80.0, 0.5) var spur_angle_jitter: float = 15.0:
	set(v):
		spur_angle_jitter = clampf(v, 0.0, 80.0)
		_param_changed()
## Sideways bend of a spur, as a fraction of its length.
@export_range(0.0, 2.0, 0.01) var spur_wander: float = 0.3:
	set(v):
		spur_wander = clampf(v, 0.0, 2.0)
		_param_changed()
## 0 = crest only, 1 = spurs, 2 = spurs off the spurs.
@export_range(0, 2, 1) var spur_levels: int = 1:
	set(v):
		spur_levels = clampi(v, 0, 2)
		_param_changed()

@export_group("Blend")
## How the range meets the input height.
@export var blend: BlendMode = BlendMode.ADD:
	set(v):
		blend = v
		_param_changed()
## Radius ridges merge over where they meet, metres. 0 = a hard crease.
@export_range(0.0, 500.0, 1.0, "or_greater") var blend_k: float = 40.0:
	set(v):
		blend_k = maxf(v, 0.0)
		_param_changed()
## Variation seed for peaks and spurs. Also a value port.
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

var _path: Pasture3DGraphPath = null


func op() -> StringName:
	return &"path_range"


## The sixteen-slot block. The order is `path_range_params_from`'s in src/pasture_3d_path_range.cpp.
func native_lower() -> Dictionary:
	return {"params": _params()}


func _params() -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = peak_height
	p[1] = peak_spacing
	p[2] = peak_variation
	p[3] = end_taper
	p[4] = end_height
	p[5] = width_ratio
	p[6] = spur_spacing
	p[7] = spur_length
	p[8] = spur_angle
	p[9] = spur_angle_jitter
	p[10] = spur_wander
	p[11] = float(spur_levels)
	p[12] = blend_k
	p[13] = 0.0 # retired (was detail)
	p[14] = float(seed)
	p[15] = float(int(crest_shape) + (4 if blend == BlendMode.MAX else 0) + (8 if use_path_heights else 0))
	return p


func native_out_count() -> int:
	return 4 # height, crest, valley, footprint


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


## Port 0 the crest; port 1 the base height (in1); port 2 the amount, the secondary grid. Ports 3 and 4
## drive slots 0 and 14.
func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"path", PortType.PATH).require(),
		Pasture3DGraphPort.field(&"height", PortType.HEIGHT).unwired(0.0),
		Pasture3DGraphPort.field(&"amount", PortType.MASK).unwired(1.0).as_aux(),
		Pasture3DGraphPort.value(&"peak_height", PortType.FLOAT, &"peak_height", 0),
		Pasture3DGraphPort.value(&"seed", PortType.INT, &"seed", 14),
	]


## Port order is a wire format: APPEND only.
func _outputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"height", PortType.HEIGHT),
		Pasture3DGraphPort.field(&"crest", PortType.MASK),
		Pasture3DGraphPort.field(&"valley", PortType.MASK),
		Pasture3DGraphPort.field(&"footprint", PortType.MASK),
	]


func reads_paths() -> bool:
	return true


func set_path_inputs(p_paths: Array) -> void:
	_path = p_paths[0] if p_paths.size() > 0 and p_paths[0] is Pasture3DGraphPath else null


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var base: PackedFloat32Array = p_inputs[1] if p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array \
			and p_inputs[1].size() == n else PackedFloat32Array()
	if not ClassDB.class_has_method("Pasture3DUtil", "path_range_grid"):
		push_error("[Pasture3D] Pasture3DUtil.path_range_grid is not bound. Rebuild GDExtension.")
		return _fallback(base, n)
	var amount: PackedFloat32Array = p_inputs[2] if p_inputs.size() > 2 and p_inputs[2] is PackedFloat32Array \
			and p_inputs[2].size() == n else PackedFloat32Array()
	var prm := _params()
	# Wired value ports arrive as cell 0 of their grid on this route, as the Leveler reads its value port.
	if p_inputs.size() > 3 and p_inputs[3] is PackedFloat32Array and p_inputs[3].size() > 0:
		prm[0] = float(p_inputs[3][0])
	if p_inputs.size() > 4 and p_inputs[4] is PackedFloat32Array and p_inputs[4].size() > 0:
		prm[14] = float(p_inputs[4][0])
	var pts := _path.points if _path != null else PackedVector2Array()
	var hts := _path.heights if _path != null else PackedFloat32Array()
	var closed := _path.closed if _path != null else false
	var res: Dictionary = Pasture3DUtil.path_range_grid(pts, hts, closed, base, amount, p_gw, p_gh, p_rect, prm,
			_path.part_starts if _path != null else PackedInt32Array())
	var h: PackedFloat32Array = res.get("height", PackedFloat32Array())
	if h.size() != n:
		push_error("[Pasture3D] path_range_grid returned %d cells for a %d cell grid." % [h.size(), n])
		return _fallback(base, n)
	return [h, res["crest"], res["valley"], res["footprint"]]


## The base passed through and empty masks: a failed solve adds no range.
func _fallback(p_base: PackedFloat32Array, p_n: int) -> Array:
	var h := p_base if p_base.size() == p_n else Pasture3DGraphOps.zeros(p_n)
	return [h, Pasture3DGraphOps.zeros(p_n), Pasture3DGraphOps.zeros(p_n), Pasture3DGraphOps.zeros(p_n)]


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if _path == null or _path.points.size() < 2:
		out.append("Path Range needs a crest path; with none it passes the height through.")
	elif use_path_heights and _path.heights.is_empty():
		out.append("Use Path Heights is on but this path carries no heights; Peak Height is used instead.")
	return out
