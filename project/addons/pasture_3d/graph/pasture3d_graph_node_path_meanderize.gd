# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathMeanderize — make a drawn line meander like a river.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §7.4. The river node, and the single biggest difference between a
# drawn river and a believable one: real channels do not go anywhere directly, and a straight line reads
# as a canal no matter what cross-section is carved along it.
#
# ---- WHAT IT ACTUALLY DOES, AND WHY NOT JUST NOISE ----
#
# Fractalize already offsets a line by noise, and the result looks like a wobbly line, not a river. The
# difference is that a meander AMPLIFIES ITS OWN CURVATURE: water cuts the outside of a bend and deposits
# on the inside, so wherever the line already turns, it turns harder next year. So each iteration pushes
# every vertex along its own normal by an amount proportional to the local curvature there, subdivides,
# and repeats. Noise is added on top and is a garnish; `ratio` is the node.
#
# ---- THE SIGN IS THE ENTIRE ALGORITHM ----
#
# Curvature is signed by the cross product of the incoming and outgoing segments, and pushing OUTWARD
# means displacing along the normal in the direction the bend already leans. Getting that sign backwards
# does not produce a mirrored river: it produces a line that straightens itself, iteration by iteration,
# converging on the chord between the endpoints. That failure is silent at one iteration and total at six,
# which is why PathShapeGate measures total length rather than eyeballing a shape — a meandering line is
# LONGER than the line it came from, and a straightened one is shorter.
#
# ---- REMOVE LOOPS ----
#
# Amplifying curvature is a positive feedback, so a tight enough bend eventually crosses itself. A path
# that self-intersects is not wrong to the query — nearest-segment still answers — but a river that flows
# through itself carves a bed twice and reads as a mistake. `remove_loops` excises the vertices between
# any two crossing segments, which is the standard cut and is why the two are one node rather than two.
@tool
class_name Pasture3DGraphNodePathMeanderize
extends Pasture3DGraphNodePathShape

## Wavelength of the meander bends in metres. Controls the physical distance along the river between
## successive loops.
@export_range(10.0, 2000.0, 1.0, "or_greater", "suffix:m") var wavelength: float = 150.0:
	set(v):
		wavelength = maxf(v, 1.0)
		_param_changed()

## Base amplitude of the meander swings in metres. Controls how far perpendicular the loops swing out.
@export_range(0.0, 500.0, 0.5, "or_greater", "suffix:m") var amplitude: float = 25.0:
	set(v):
		amplitude = maxf(v, 0.0)
		_param_changed()

## How hard each iteration pushes a bend outward, as a fraction of the local segment length. The useful
## range is small: 0.3 over six iterations is already a floodplain river. 0 is the identity.
@export_range(0.0, 2.0, 0.001) var ratio: float = 0.4:
	set(v):
		ratio = maxf(v, 0.0)
		_param_changed()

## Random displacement added on top, as a fraction of the local segment length. A garnish — see the
## header. It is what stops every bend being the same bend, and it cannot make a straight line meander.
@export_range(0.0, 1.0, 0.001) var noise_ratio: float = 0.1:
	set(v):
		noise_ratio = maxf(v, 0.0)
		_param_changed()

## The seed. Stable, for the reason Path Fractalize's header gives at length: the generator is seeded once
## and consumed in a fixed order, and anything that reorders the walk moves the terrain under a frozen
## graph.
@export var seed: int = 0:
	set(v):
		seed = v
		_param_changed()

## How many times to amplify. Each iteration multiplies the vertex count by `edge_divisions`, so this and
## that knob together are the cost.
@export_range(1, 10, 1) var iterations: int = 4:
	set(v):
		iterations = clampi(v, 1, 10)
		_param_changed()

## Minimum segment length in metres below which edges will not be subdivided.
## Prevents vertex explosion on already-dense or repeatedly iterated paths.
@export_range(1.0, 100.0, 0.5, "or_greater", "suffix:m") var min_segment_length: float = 5.0:
	set(v):
		min_segment_length = maxf(v, 0.1)
		_param_changed()

## How many pieces each edge becomes per iteration (1 = no in-loop subdivision, only bend amplification).
## 2 or more subdivides edges longer than `min_segment_length`.
@export_range(1, 8, 1) var edge_divisions: int = 1:
	set(v):
		edge_divisions = clampi(v, 1, 8)
		_param_changed()

## Cut out any loop the amplification produces. See the header.
@export var remove_loops: bool = true:
	set(v):
		remove_loops = v
		_param_changed()

## Hold the first and last vertices — a river's mouth and source are placed, not derived. Ignored when
## the path is closed.
@export var pin_ends: bool = true:
	set(v):
		pin_ends = v
		_param_changed()

## Above this the node stops iterating and keeps what it has, rather than passing the input through: a
## meander that got most of the way there is still a meander, unlike a half-resampled path.
const MAX_POINTS: int = 200000


func min_vertices() -> int:
	return 2


func op() -> StringName:
	return &"path_meanderize"


func reshape(p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	if ratio <= 0.0 and noise_ratio <= 0.0:
		return

	if not ClassDB.class_has_method("Pasture3DUtil", "path_meanderize_solve"):
		push_error("Pasture3DGraphNodePathMeanderize: Pasture3DUtil.path_meanderize_solve is missing from GDExtension!")
		return

	var res: Dictionary = Pasture3DUtil.path_meanderize_solve(
		p_src.points,
		p_src.half_widths,
		p_src.heights,
		p_src.closed,
		wavelength,
		amplitude,
		ratio,
		noise_ratio,
		seed,
		iterations,
		min_segment_length,
		edge_divisions,
		remove_loops,
		pin_ends
	)

	if res.is_empty():
		return

	p_out.points = res.get("points", PackedVector2Array())
	p_out.half_widths = res.get("half_widths", PackedFloat32Array())
	p_out.heights = res.get("heights", PackedFloat32Array())


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if ratio <= 0.0 and noise_ratio <= 0.0:
		out.append("Path Meanderize is the identity: both ratio and noise ratio are 0, so the path "
				+ "passes through unchanged.")
	elif ratio <= 0.0:
		out.append("Path Meanderize's ratio is 0, so it is only adding noise — it cannot make a "
				+ "straight line meander, because it amplifies curvature that is already there.")
	return out
