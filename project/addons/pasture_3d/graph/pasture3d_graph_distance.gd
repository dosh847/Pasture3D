# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphDistance — the GDScript definition of the graph's distance metrics and repeat modes, and
# the ORACLE the native and GPU copies are gated against (PASTURE3D_GRADIENT_AND_COLOR_RAMP_SPEC.md §3).
#
# Written from the spec's definitions, not transcribed from src/pasture_3d_distance_metric.h. A transcription
# agreeing with its source proves only that it was copied carefully.
#
# Metrics take a UNIT direction, not an end point: see that header for why Falloff's bit-identity depends
# on it. `direction()` is the one place an end point becomes a direction.
@tool
class_name Pasture3DGraphDistance
extends RefCounted

## Values are serialised (Falloff.Shape uses 0-3). Append only.
enum Metric { RADIAL, SQUARE, AXIS_X, AXIS_Z, LINEAR, REFLECTED, DIAMOND, ANGULAR }

## Values are serialised. Append only.
enum Repeat { CLAMP, REPEAT, MIRROR }


## Unit direction from `p_a` to `p_b`; +X when they are under 1e-6 m apart.
static func direction(p_a: Vector2, p_b: Vector2) -> Vector2:
	var v := p_b - p_a
	var len := v.length()
	if not (len >= 1.0e-6):
		return Vector2(1.0, 0.0)
	return v / len


## Distance from world (`p_wx`, `p_wz`) to `p_a` under `p_metric`, in the frame of unit `p_u`. Metres,
## except ANGULAR (radians in [0, TAU)). An unknown metric measures RADIAL.
static func metric(p_metric: int, p_wx: float, p_wz: float, p_a: Vector2, p_u: Vector2) -> float:
	var dx := p_wx - p_a.x
	var dz := p_wz - p_a.y
	# Along u, and u turned a quarter: the frame SQUARE, DIAMOND, LINEAR and ANGULAR are measured in.
	var along := dx * p_u.x + dz * p_u.y
	var across := dz * p_u.x - dx * p_u.y
	match p_metric:
		Metric.SQUARE:
			return maxf(absf(along), absf(across))
		Metric.AXIS_X:
			return absf(dx)
		Metric.AXIS_Z:
			return absf(dz)
		Metric.LINEAR:
			return along
		Metric.REFLECTED:
			return absf(along)
		Metric.DIAMOND:
			return absf(along) + absf(across)
		Metric.ANGULAR:
			return fposmod(atan2(across, along), TAU)
	return sqrt(dx * dx + dz * dz)


## Fold a normalised coordinate. A non-finite value passes through untouched.
static func repeat(p_mode: int, p_t: float) -> float:
	if not is_finite(p_t):
		return p_t
	match p_mode:
		Repeat.REPEAT:
			return p_t - floorf(p_t)
		Repeat.MIRROR:
			# Triangle wave of period 2: 0 at even integers, 1 at odd ones.
			return 1.0 - absf(fposmod(p_t, 2.0) - 1.0)
	return clampf(p_t, 0.0, 1.0)
