# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeGradient — a GENERATOR cell node: a metric gradient between two points
# (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md §4).
#
# CELL node, one output, so it folds into the per-cell program. The distance is the shared metric
# (Pasture3DGraphDistance / pasture_3d_distance_metric.h), so a gradient measures the way a Falloff does.
#
# ---- HOST SPACE, AND WHY THE KERNEL PLACES start / end ----
#
# In HOST space, start and end are metres relative to the brush that runs the graph. The graph is a
# Resource and cannot see the brush, so Pasture3DGraphSources.resolve stamps a placement here
# (`set_host_placement`). The spec (§4.3) placed the points in native_lower; that cannot survive a DRIVEN
# start_x, which is resolved into the param block after lowering. So the placement is lowered beside the
# node-space points (slots 13-15) and gradient_frame() in C++ places both, property or wire alike.
@tool
class_name Pasture3DGraphNodeGradient
extends Pasture3DGraphNode

## Values are serialised. Append only.
enum Space { HOST, WORLD }
enum Shape { LINEAR, REFLECTED, RADIAL, SPHERICAL, SQUARE, DIAMOND, ANGULAR }
enum Profile { LINEAR, SMOOTH, EASE_IN, EASE_OUT, EXPONENTIAL, CURVE }
enum Repeat { CLAMP, REPEAT, MIRROR }
enum OutputMode { MASK, HEIGHT }

const LUT_SIZE := 256
## Shape -> Pasture3DGraphDistance.Metric. Sync with k_gradient_metric in pasture_3d_math_ops.cpp.
const SHAPE_METRIC := [4, 5, 0, 0, 1, 6, 7]
const COORD_LIMIT := 16000.0

## Picks the metric and how distance becomes t.
@export var shape: Shape = Shape.RADIAL:
	set(v):
		shape = v
		emit_changed()

@export_group("Placement")
## HOST: start / end are metres relative to the host brush, following its position and yaw.
## WORLD: absolute world metres.
@export var space: Space = Space.HOST:
	set(v):
		space = v
		emit_changed()

## The linear origin, or the radial centre (x, z metres).
@export var start: Vector2 = Vector2.ZERO:
	set(v):
		start = v
		emit_changed()

## The t = 1 point for LINEAR, or any point on the radius (x, z metres).
@export var end: Vector2 = Vector2(500.0, 0.0):
	set(v):
		end = v
		emit_changed()

@export_group("Profile")
@export var profile: Profile = Profile.LINEAR:
	set(v):
		profile = v
		emit_changed()

## The EXPONENTIAL exponent.
@export_range(0.05, 16.0, 0.01) var hardness: float = 2.0:
	set(v):
		hardness = clampf(v, 0.05, 16.0)
		emit_changed()

## Used when Profile is CURVE.
@export var curve: Curve:
	set(v):
		if curve != null and curve.changed.is_connected(emit_changed):
			curve.changed.disconnect(emit_changed)
		curve = v
		if curve != null and not curve.changed.is_connected(emit_changed):
			curve.changed.connect(emit_changed)
		emit_changed()

## Applied before the profile.
@export var repeat: Repeat = Repeat.CLAMP:
	set(v):
		repeat = v
		emit_changed()

## t -> 1 - t, after the profile.
@export var invert: bool = false:
	set(v):
		invert = v
		emit_changed()

@export_group("Output")
## MASK is [0, 1]; HEIGHT is lerp(height_min, height_max, t) in metres.
@export var output_mode: OutputMode = OutputMode.MASK:
	set(v):
		output_mode = v
		notify_property_list_changed()
		emit_changed()

@export var height_min: float = 0.0:
	set(v):
		height_min = v
		emit_changed()

@export var height_max: float = 100.0:
	set(v):
		height_max = v
		emit_changed()

@export_group("Warp")
## Metres of distance perturbation from the `warp` port.
@export_range(0.0, 500.0, 0.1, "or_greater") var distance_noise: float = 0.0:
	set(v):
		distance_noise = maxf(v, 0.0)
		emit_changed()

## The host's ground-plane placement (§4.3). Identity until a host stamps one.
var host_xform: Transform2D = Transform2D.IDENTITY
var _placement_received := false


func _init() -> void:
	super()


## Called by Pasture3DGraphSources.resolve. Emits `changed` only when the placement moved beyond 1e-4 m or
## 1e-5 rad: a signal on every resolve would defeat every cache, and none would leave a moved brush stale.
func set_host_placement(p_xform: Transform2D) -> void:
	var first := not _placement_received
	_placement_received = true
	var moved := host_xform.origin.distance_to(p_xform.origin) > 1.0e-4 \
			or absf(angle_difference(host_xform.x.angle(), p_xform.x.angle())) > 1.0e-5
	if not moved:
		if first:
			notify_property_list_changed() # the warning goes away; the field does not change
		return
	host_xform = p_xform
	emit_changed()


## The placement start / end are measured through: the host's in HOST space, identity in WORLD.
func placement() -> Transform2D:
	return host_xform if space == Space.HOST else Transform2D.IDENTITY


func op() -> StringName:
	return &"gradient"


func role() -> Role:
	return Role.GENERATOR


func needs_grid() -> bool:
	return false


func input_count() -> int:
	return 7


func input_names() -> PackedStringArray:
	return PackedStringArray(["warp", "start_x", "start_z", "end_x", "end_z", "height_min", "height_max"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.FIELD, PortType.FLOAT, PortType.FLOAT, PortType.FLOAT, PortType.FLOAT,
			PortType.FLOAT, PortType.FLOAT])


func output_port_type() -> int:
	return PortType.HEIGHT if output_mode == OutputMode.HEIGHT else PortType.MASK


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([output_port_type()])


func native_param_ports() -> PackedInt32Array:
	return PackedInt32Array([-1, 1, 2, 3, 4, 5, 6])


func input_unwired_default(p_port: int) -> float:
	match p_port:
		1: return start.x
		2: return start.y
		3: return end.x
		4: return end.y
		5: return height_min
		6: return height_max
	return 0.0


func curve_lut() -> PackedFloat32Array:
	var lut := PackedFloat32Array()
	if profile == Profile.CURVE and curve != null:
		lut.resize(LUT_SIZE)
		for i in LUT_SIZE:
			lut[i] = curve.sample_baked(float(i) / float(LUT_SIZE - 1))
	return lut


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	var xf := placement()
	p[0] = float(shape)
	p[1] = start.x
	p[2] = start.y
	p[3] = end.x
	p[4] = end.y
	p[5] = height_min
	p[6] = height_max
	p[7] = float(profile)
	p[8] = hardness
	p[9] = float(repeat)
	p[10] = 1.0 if invert else 0.0
	p[11] = float(output_mode)
	p[12] = distance_noise
	p[13] = xf.origin.x
	p[14] = xf.origin.y
	p[15] = xf.x.angle()
	return {"params": p, "lut": curve_lut()}


func eval_cell(p_wx: float, p_wz: float, p_inputs: PackedFloat32Array) -> float:
	return evaluate_at(p_wx, p_wz, p_inputs, curve_lut())


## The definition (§4.4). Kept here rather than only on the [Dev/GD] node so the GDScript fallback evaluator
## answers the same thing; the dev node is this with native blocked. Reads the LOWERED LUT, not the Curve,
## so the oracle samples the table the kernels sample.
func evaluate_at(p_wx: float, p_wz: float, p_inputs: PackedFloat32Array, p_lut: PackedFloat32Array) -> float:
	var warp := _in(p_inputs, 0, 0.0)
	var xf := Transform2D(Vector2.from_angle(placement().x.angle()), Vector2.ZERO, placement().origin)
	xf.y = Vector2(-xf.x.y, xf.x.x)
	var a: Vector2 = xf * Vector2(_in(p_inputs, 1, start.x), _in(p_inputs, 2, start.y))
	var b: Vector2 = xf * Vector2(_in(p_inputs, 3, end.x), _in(p_inputs, 4, end.y))
	var hmin := _in(p_inputs, 5, height_min)
	var hmax := _in(p_inputs, 6, height_max)
	var len := maxf(a.distance_to(b), 1.0e-3)
	var u := Pasture3DGraphDistance.direction(a, b)
	var d := Pasture3DGraphDistance.metric(SHAPE_METRIC[shape], p_wx, p_wz, a, u)
	if is_finite(warp):
		d += distance_noise * warp * ((1.0 / len) if shape == Shape.ANGULAR else 1.0)
	var t: float
	match shape:
		Shape.LINEAR, Shape.REFLECTED, Shape.SPHERICAL:
			# SPHERICAL: u = d / L folded, then domed below. Folding 1 - d/L agrees only at L/2.
			t = d / len
		Shape.ANGULAR:
			t = d / TAU
		_:
			t = 1.0 - d / len
	t = Pasture3DGraphDistance.repeat(repeat, t)
	if shape == Shape.SPHERICAL:
		t = sqrt(maxf(0.0, 1.0 - t * t))
	match profile:
		Profile.SMOOTH:
			t = t * t * (3.0 - 2.0 * t)
		Profile.EASE_IN:
			t = t * t
		Profile.EASE_OUT:
			t = 1.0 - (1.0 - t) * (1.0 - t)
		Profile.EXPONENTIAL:
			t = pow(maxf(t, 0.0), hardness)
		Profile.CURVE:
			if p_lut.size() >= 2:
				var f := clampf(t, 0.0, 1.0) * float(p_lut.size() - 1)
				var i0 := mini(int(f), p_lut.size() - 2)
				t = lerpf(p_lut[i0], p_lut[i0 + 1], f - float(i0))
	if invert:
		t = 1.0 - t
	return lerpf(hmin, hmax, t) if output_mode == OutputMode.HEIGHT else t


func _in(p_inputs: PackedFloat32Array, p_port: int, p_default: float) -> float:
	if p_inputs.size() > p_port and not is_nan(p_inputs[p_port]):
		return p_inputs[p_port]
	return p_default


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if profile == Profile.CURVE and curve == null:
		w.append("%s: Profile is Curve but no Curve is assigned, so Linear is used." % display_name())
	if start.distance_to(end) < 1.0e-3:
		w.append("%s: Start and End are the same point, so the gradient has no length." % display_name())
	if space == Space.HOST and not _placement_received:
		w.append("%s: Host space, but no brush has placed this graph yet, so it measures in world space." % display_name())
	var xf := placement()
	for pt in [xf * start, xf * end]:
		if absf(pt.x) > COORD_LIMIT or absf(pt.y) > COORD_LIMIT:
			w.append("%s: a point lies beyond 16 km, where the GPU's float32 coordinates lose millimetres." % display_name())
			break
	if output_mode == OutputMode.HEIGHT and is_equal_approx(height_min, height_max):
		w.append("%s: Height Min equals Height Max, so the output is flat." % display_name())
	return w
