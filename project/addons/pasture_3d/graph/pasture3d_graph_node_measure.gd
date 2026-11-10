# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeMeasure — reduce a field to two numbers that a wire can carry into any scalar port:
# RANGE (min, max), PERCENTILE (low, high) or MEAN (mean, std dev). Measure's min/max wired into a Curve's
# in_min/in_max is a live Auto Fit; with the Curve's Output Range on SAME_AS_INPUT the curve then reshapes
# the distribution and keeps the scale, re-measured on every bake.
#
# Both outputs are UNIFORM grids. A driven scalar port reads cell 0 of its source (see the Const node's
# header), and a field port reads every cell, so the two readings are the same number.
#
# ---- WHAT IS MEASURED ----
#
# Every finite cell of the evaluated grid, and only those whose `selection` is >= 0.5 when one is wired.
# A brush hands its graph NaN outside the footprint, so the footprint is excluded for free. The rules
# (exact percentiles, sum order, the empty case) are src/pasture_3d_measure.h's; the GDScript oracle is
# Pasture3DGraphNodeDevMeasure.
#
# ---- LIVE IS NOT LOCAL ----
#
# A live measurement depends on the whole evaluated area, so `edit_reach()` is INF and a point drag on a
# brush using it re-bakes the whole footprint rather than a rect. It also means two brushes measure two
# different fields and can disagree at a seam — World Machine refuses to auto-normalise exports for the
# same reason. Lock pins the values (type them, or Capture them from the graph editor's preview) and makes
# the node a constant again: local, seamless and cheap.
@tool
class_name Pasture3DGraphNodeMeasure
extends Pasture3DGraphNode

## Values are serialised. Append only. Sync with MeasureMode in src/pasture_3d_measure.h.
enum Mode { RANGE, PERCENTILE, MEAN }

## RANGE: min and max. PERCENTILE: the low and high percentiles (a range one spike cannot wreck).
## MEAN: the mean and the population standard deviation.
@export var mode: Mode = Mode.RANGE:
	set(v):
		mode = v
		notify_property_list_changed()
		emit_changed()

## PERCENTILE: the first output. 50 is the median.
@export_range(0.0, 100.0, 0.1) var low_percentile: float = 1.0:
	set(v):
		low_percentile = clampf(v, 0.0, 100.0)
		emit_changed()

## PERCENTILE: the second output.
@export_range(0.0, 100.0, 0.1) var high_percentile: float = 99.0:
	set(v):
		high_percentile = clampf(v, 0.0, 100.0)
		emit_changed()

@export_group("Lock")
## Output the two values below instead of measuring. Local and seamless; see the header.
@export var locked: bool = false:
	set(v):
		locked = v
		emit_changed()

## The first output while locked (min / low / mean). Capture fills it from the graph editor's preview.
@export var locked_a: float = 0.0:
	set(v):
		locked_a = v
		emit_changed()

## The second output while locked (max / high / std dev).
@export var locked_b: float = 0.0:
	set(v):
		locked_b = v
		emit_changed()

## Measures the upstream field in the graph editor's preview and writes the result into Locked A/B. The
## preview is coarser than a bake, so a captured min/max can sit slightly inside the baked one.
@export_tool_button("Capture") var _capture_btn = _request_capture


func _request_capture() -> void:
	editor_action_requested.emit(&"capture")


func _validate_property(p_property: Dictionary) -> void:
	if mode != Mode.PERCENTILE and p_property.name in ["low_percentile", "high_percentile"]:
		p_property.usage &= ~PROPERTY_USAGE_EDITOR


func op() -> StringName:
	return &"measure"


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


## INF live (every cell can move the answer); 0 locked, where the node is a constant.
func edit_reach() -> float:
	return 0.0 if locked else INF


## An unwired selection is fully open, so every finite cell counts.
func _inputs() -> Array[Pasture3DGraphPort]:
	return [
		Pasture3DGraphPort.field(&"in", PortType.HEIGHT).require(),
		Pasture3DGraphPort.field(&"selection", PortType.MASK).unwired(1.0).as_aux(),
	]


# The two outputs keep ONE identity each across modes (`min`, `max` — a saved wire names the id), and
# only their label follows the mode: a wire out of "low" is still wired when the mode becomes MEAN.
func _outputs() -> Array[Pasture3DGraphPort]:
	var lo := "min"
	var hi := "max"
	match mode:
		Mode.PERCENTILE:
			lo = "low"
			hi = "high"
		Mode.MEAN:
			lo = "mean"
			hi = "std_dev"
	return [
		Pasture3DGraphPort.value(&"min", PortType.FLOAT).labelled(lo),
		Pasture3DGraphPort.value(&"max", PortType.FLOAT).labelled(hi),
	]


func native_out_count() -> int:
	return 2


func native_lower() -> Dictionary:
	var p := PackedFloat32Array()
	p.resize(16)
	p[0] = float(mode)
	p[1] = low_percentile
	p[2] = high_percentile
	p[3] = 1.0 if locked else 0.0
	p[4] = locked_a
	p[5] = locked_b
	return {"params": p}


## [a, b, count] for one grid and its selection, through the native reduction. The oracle overrides this.
func measure(p_values: PackedFloat32Array, p_selection: PackedFloat32Array) -> PackedFloat64Array:
	return Pasture3DUtil.measure_field(p_values, p_selection, mode, low_percentile, high_percentile)


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


func eval_grid_channels(p_inputs: Array, p_gw: int, p_gh: int, _p_mask, _p_rect: Rect2) -> Array:
	var n := p_gw * p_gh
	var a := locked_a
	var b := locked_b
	if not locked:
		var h: PackedFloat32Array = (p_inputs[0] as PackedFloat32Array) if (p_inputs.size() > 0 and p_inputs[0] is PackedFloat32Array and p_inputs[0].size() == n) else Pasture3DGraphOps.zeros(n)
		var sel: PackedFloat32Array = (p_inputs[1] as PackedFloat32Array) if (p_inputs.size() > 1 and p_inputs[1] is PackedFloat32Array and p_inputs[1].size() == n) else PackedFloat32Array()
		var r := measure(h, sel)
		a = r[0]
		b = r[1]
	var ga := PackedFloat32Array()
	ga.resize(n)
	ga.fill(a)
	var gb := PackedFloat32Array()
	gb.resize(n)
	gb.fill(b)
	return [ga, gb]


func node_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if mode == Mode.PERCENTILE and low_percentile > high_percentile:
		w.append("%s: Low Percentile is above High Percentile, so the outputs are reversed." % display_name())
	return w


func node_warnings_in_brush() -> PackedStringArray:
	var w := PackedStringArray()
	if not locked:
		w.append(("%s measures live: every bake re-measures the brush's whole footprint, so point drags re-bake "
				+ "all of it and neighbouring brushes can disagree at a seam. Lock it (Capture) for final work.")
				% display_name())
	return w
