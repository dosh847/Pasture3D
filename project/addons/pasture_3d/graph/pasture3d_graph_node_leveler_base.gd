# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeLevelerBase — what the Leveler and its [Dev/GD] oracle SHARE: parameters, ports, the
# falloff table and the warnings. Never placed in a graph itself.
#
# ---- WHY A BASE, WHEN PATH CARVE DUPLICATES ITS PARAMETERS ----
#
# Path Carve's two classes each declare the same parameters, and its gate sets them by name so a parameter
# forgotten on one shows as a disagreement. That catches drift after the fact. Here the parameters, the
# port order, the unwired defaults and the LUT bake are declared ONCE, so they cannot drift at all; the two
# subclasses differ only in how they compute (GDScript maths versus the native kernel), which is the one
# difference the parity gate exists to measure. See PASTURE3D_GRAPH_LEVELER_SPEC.md.
@tool
class_name Pasture3DGraphNodeLevelerBase
extends Pasture3DGraphNode

enum Mode { FLATTEN, LEVEL_AT_HEIGHT }
enum Statistic { MEAN, MEDIAN, MIN, MAX }
enum CutFill { BOTH, CUT_ONLY, FILL_ONLY }
enum WallsShape { BAND, SLOPE }

## Rows per summation block for the mean. MUST match LEVELER_MEAN_BLOCK_ROWS in src/pasture_3d_leveler.h.
const MEAN_BLOCK_ROWS := 64
## A mask value counts as fully inside at or above 1 - this. MUST match LEVELER_CORE_EPS.
const CORE_EPS := 1.0e-6
const LUT_SIZE := 256

## Flatten to a statistic of the terrain inside the area, or level to an authored height.
@export var mode: Mode = Mode.FLATTEN:
	set(v):
		mode = v
		emit_changed()

## Flatten only. Computed over fully-inside cells, never the feather. MEDIAN is the lower median.
@export var statistic: Statistic = Statistic.MEAN:
	set(v):
		statistic = v
		emit_changed()

## Level at Height only. World Y in metres; the `target_height` socket overrides it when wired.
@export var target_height: float = 0.0:
	set(v):
		target_height = v
		emit_changed()

## Both moves every cell; Cut Only only lowers ground above the level; Fill Only only raises ground below.
@export var cut_fill: CutFill = CutFill.BOTH:
	set(v):
		cut_fill = v
		emit_changed()

@export_group("Walls")
## Wall width in metres, built OUTSIDE the area. 0 is a hard edge.
@export_range(0.0, 200.0, 0.1, "or_greater") var feather: float = 5.0:
	set(v):
		feather = maxf(v, 0.0)
		emit_changed()

## Use the loop's own half-width, at the nearest point on the loop, as the wall width. Inert without a
## loop — `feather` applies then.
@export var feather_from_path_width: bool = false:
	set(v):
		feather_from_path_width = v
		emit_changed()

## Multiplies the loop's half-width when `feather_from_path_width` is on.
@export_range(0.0, 8.0, 0.01, "or_greater") var path_width_scale: float = 1.0:
	set(v):
		path_width_scale = maxf(v, 0.0)
		emit_changed()

## The wall's profile: X is 0 at the area edge and 1 at the feather edge, Y is the leveling weight.
## Unassigned = 1 - smoothstep.
@export var falloff: Curve:
	set(v):
		if falloff != null and falloff.changed.is_connected(emit_changed):
			falloff.changed.disconnect(emit_changed)
		falloff = v
		if falloff != null and not falloff.changed.is_connected(emit_changed):
			falloff.changed.connect(emit_changed)
		emit_changed()

## BAND is 1 across the wall; SLOPE follows the falloff's steepness.
@export var walls_shape: WallsShape = WallsShape.BAND:
	set(v):
		walls_shape = v
		emit_changed()

## Metres a cell has to move for `walls` to reach full strength.
@export_range(0.0, 50.0, 0.01, "or_greater") var wall_depth: float = 1.0:
	set(v):
		wall_depth = maxf(v, 0.0)
		emit_changed()

@export_group("Advanced")
## Histogram resolution for MEDIAN. The error bound is (max - min) / bins over the area, against the
## lower median.
@export_range(16, 65536, 1) var median_bins: int = 4096:
	set(v):
		median_bins = clampi(v, 16, 65536)
		emit_changed()

var _path: Pasture3DGraphPath = null
var _loop_open: bool = false

## Set by the last GDScript-side evaluation, read by the gates and the warnings. Does not exist on the
## lowered route — a graph solved natively never touches the node.
var last_level: float = NAN
var last_core_count: int = 0
var evaluated: bool = false


func role() -> Role:
	return Role.FILTER


func needs_grid() -> bool:
	return true


func input_count() -> int:
	return 4


func input_names() -> PackedStringArray:
	return PackedStringArray(["height", "loop", "mask", "target_height"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.PATH, PortType.MASK, PortType.FLOAT])


## An unwired mask is fully open; an unwired target reads the inspector value, so a wire overrides it and
## nothing else has to ask whether the port is connected (the Contrast `amount` idiom).
func input_unwired_default(p_port: int) -> float:
	match p_port:
		2: return 1.0
		3: return target_height
	return 0.0


func output_count() -> int:
	return 5


func output_names() -> PackedStringArray:
	return PackedStringArray(["height", "level_mask", "level_value", "delta", "walls"])


func output_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.HEIGHT, PortType.MASK, PortType.FLOAT, PortType.SIGNED, PortType.MASK])


func reads_paths() -> bool:
	return true


## Port-indexed: the loop is port 1. A path is a loop only when closed with at least three points — the
## same test the native geometry table applies, so the two routes agree on a degenerate ring.
func set_path_inputs(p_paths: Array) -> void:
	var p = p_paths[1] if p_paths.size() > 1 else null
	_path = null
	_loop_open = false
	if p is Pasture3DGraphPath and (p as Pasture3DGraphPath).segment_count() > 0:
		if (p as Pasture3DGraphPath).closed and (p as Pasture3DGraphPath).points.size() >= 3:
			_path = p
		else:
			_loop_open = true


func eval_grid(p_inputs: Array, p_gw: int, p_gh: int, p_mask, p_rect: Rect2) -> PackedFloat32Array:
	return eval_grid_channels(p_inputs, p_gw, p_gh, p_mask, p_rect)[0]


## The falloff as the 256-entry table both routes read. Always full: the analytic default is baked too, so
## the kernel never has a second definition of it.
func falloff_lut() -> PackedFloat32Array:
	var lut := PackedFloat32Array()
	lut.resize(LUT_SIZE)
	for i in LUT_SIZE:
		var x := float(i) / float(LUT_SIZE - 1)
		lut[i] = falloff.sample_baked(x) if falloff != null else 1.0 - x * x * (3.0 - 2.0 * x)
	return lut


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if _loop_open:
		out.append("Leveler: the loop is an open path, so it is ignored. Close it to use it as an area.")
	if feather_from_path_width and _path == null:
		out.append("Leveler: Feather From Path Width needs a closed loop wired in; Feather applies instead.")
	if evaluated and last_core_count == 0:
		out.append("Leveler: no cell is fully inside the area, so the height passes through unchanged.")
	return out
