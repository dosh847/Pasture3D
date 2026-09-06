# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodePathFromFlow — trace a river out of a flow-accumulation field.
#
# See PASTURE3D_SPLINE_GRAPH_SPEC.md §7.5, §8.4. The third GRID → PATH node and the only one in the whole
# graph that produces a PATH from no path at all: the line comes out of the water, not out of a spline
# somebody drew.
#
# ---- THE TRACE RUNS UPSTREAM AND THE PATH COMES BACK DOWNSTREAM ----
#
# Flow accumulation increases downstream — every cell counts the cells draining through it — so its
# maximum is the outlet and its minima are the whole hillside. That asymmetry decides the algorithm:
#
#   seed at the outlet, then repeatedly step to the neighbouring cell with the HIGHEST accumulation
#   among those not yet visited, until the accumulation falls under `min_flow` or the walk leaves the
#   domain. Then REVERSE the result.
#
# Walking that way follows the main stem by construction — at every confluence the larger tributary is
# the larger number, which is exactly the branch a river's name follows. Walking downstream from a
# hilltop instead would need a tie-break at every one of those confluences and would produce a different
# river depending on which hilltop was picked. The reversal at the end is not cosmetic: `Path Drape`'s
# force-downhill, `Pasture3DStream` and arc length `s` all read vertex 0 as the head of the line.
#
# ---- WHY IT IS ONE STEM AND NOT A NETWORK ----
#
# A PATH is a polyline. A drainage network is a tree, and there is no port type for one; expressing it
# would mean this node emitting N paths, which the geometry table, the carve and the whole PATH sideband
# are not shaped for. So this traces the main stem, and a second tributary is a second node with its own
# seed — visible in the graph, wired to its own carve, with its own width. That is a real limitation and
# it is stated here rather than discovered: §12.3 is where a network belongs if one is ever wanted.
#
# ---- STEPPING BY CELL, THEN DECIMATING ----
#
# The raw walk emits one vertex per cell, which on a 512² domain is a path of hundreds of vertices at a
# spacing that has nothing to do with the river and everything to do with the grid. `step_cells` walks
# more than one cell at a time and `Path Smooth` / `Path Decimate` downstream do the rest — the family
# already exists and this node does not duplicate it.
@tool
class_name Pasture3DGraphNodePathFromFlow
extends Pasture3DGraphNodePathDerive

## Where the trace starts.
##
## OUTLET is the cell of maximum accumulation, which is the mouth of the largest river in the domain and
## needs no input from the user at all. POINT is a world XZ, for a specific watercourse: the trace snaps
## to the highest-accumulation cell within `seed_radius` of it, so a click near a valley floor finds the
## channel rather than the hillside it landed on.
enum Seed { OUTLET, POINT }

@export var seed_mode: Seed = Seed.OUTLET:
	set(v):
		seed_mode = v
		emit_changed()
		notify_property_list_changed()

## POINT only: world XZ to seed near.
@export var seed_point: Vector2 = Vector2.ZERO:
	set(v):
		seed_point = v
		emit_changed()

## POINT only: metres searched around `seed_point` for the highest-accumulation cell.
@export_range(0.0, 500.0, 0.5, "or_greater", "suffix:m") var seed_radius: float = 20.0:
	set(v):
		seed_radius = maxf(v, 0.0)
		emit_changed()

## Stop when the accumulation under the walk falls below this. The headwater threshold, and the one
## number that decides how far up the hill the river reaches.
##
## In the same units as the field, which for `Erosion.flow` is whatever that solver reports — hence
## `node_warnings` telling the user to read it off the preview rather than the node pretending to know.
@export_range(0.0, 10000.0, 0.001, "or_greater") var min_flow: float = 0.05:
	set(v):
		min_flow = maxf(v, 0.0)
		emit_changed()

## Cells per step. 1 emits a vertex per cell; larger strides thin the line at the source instead of
## downstream, which costs less and loses the wiggle a `Path Meanderize` would put back anyway.
@export_range(1, 32, 1) var step_cells: int = 2:
	set(v):
		step_cells = maxi(v, 1)
		emit_changed()

## Hard ceiling on vertices. A safety rail rather than a shape control: the visited-set already
## terminates the walk, and this bounds the cost when a pathological field makes it wander.
@export_range(8, 4096, 1) var max_points: int = 512:
	set(v):
		max_points = maxi(v, 8)
		emit_changed()

## Half-width written at every vertex of the traced line.
##
## A constant, deliberately: the node that makes a river widen downstream is Path Width from Field, wired
## straight below this one and reading the same flow. Two ways to set a width inside one node is how the
## two disagree.
@export_range(0.0, 200.0, 0.01, "or_greater", "suffix:m") var half_width: float = 4.0:
	set(v):
		half_width = maxf(v, 0.0)
		emit_changed()


func op() -> StringName:
	return &"path_from_flow"


## A GENERATOR: it has no path input at all. This is the answer `derives_path_from_grid()` exists to keep
## `_resolved_path_of` from short-circuiting past.
func role() -> Role:
	return Role.GENERATOR


func path_input_port() -> int:
	return -1


func input_count() -> int:
	return 2


func input_names() -> PackedStringArray:
	return PackedStringArray(["flow", "surface"])


func input_port_types() -> PackedInt32Array:
	return PackedInt32Array([PortType.MASK, PortType.HEIGHT])


## NAN on both, so each can be told apart from a field that is genuinely zero. `flow` unwired means the
## node produces nothing; `surface` unwired means the traced line carries no heights, which is a
## perfectly good river for a `Path Carve` reading its bed from the terrain.
func input_unwired_default(_p_port: int) -> float:
	return NAN


## No capture, no river. Unlike the two filters there is no input to pass through — see
## Pasture3DGraphNodePathDerive.derive_without_grid.
func derive_without_grid(_p_src: Pasture3DGraphPath) -> Pasture3DGraphPath:
	return null


func _derive_path(p_inputs: Array) -> Pasture3DGraphPath:
	var made := super(p_inputs)
	# A trace that found nothing is NOT a path of one vertex: `Pasture3DGraphPath` answers every query
	# with INF below two points, so an empty result and a one-point result behave identically downstream,
	# and returning null says the same thing where a warning can also be attached.
	if made != null and made.points.size() < 2:
		return null
	return made


func derive(_p_src: Pasture3DGraphPath, p_out: Pasture3DGraphPath) -> void:
	p_out.closed = false
	p_out.alignment = null
	p_out.points = PackedVector2Array()
	p_out.half_widths = PackedFloat32Array()
	p_out.heights = PackedFloat32Array()
	if port_unwired(0):
		return
	var flow: PackedFloat32Array = _grids[0]
	if flow.size() < _gw * _gh:
		return

	var start := _seed_cell(flow)
	if start < 0:
		return

	# Visited as a byte per cell rather than a Dictionary: the walk asks about eight neighbours per step
	# and a hashed lookup per ask is the whole cost of the node on a large domain.
	var seen := PackedByteArray()
	seen.resize(_gw * _gh)
	var cells := PackedInt32Array()
	var cur := start
	seen[cur] = 1
	cells.append(cur)
	while cells.size() < max_points:
		var nxt := _best_neighbour(flow, seen, cur)
		if nxt < 0:
			break
		# Mark every cell the stride passes over, not just the ones emitted: without it a stride of 2 can
		# turn around and walk back up the channel it just came down, because the cell behind it was
		# never marked.
		seen[nxt] = 1
		cur = nxt
		var stepped := 1
		while stepped < step_cells:
			var s2 := _best_neighbour(flow, seen, cur)
			if s2 < 0:
				break
			seen[s2] = 1
			cur = s2
			stepped += 1
		if flow[cur] < min_flow:
			# The threshold is checked AFTER the step, so the vertex that crosses it is dropped rather
			# than kept: a river should stop at its headwater, not one cell past it.
			break
		cells.append(cur)

	# Reverse: the trace ran upstream and vertex 0 has to be the head of the line. See the header.
	var n := cells.size()
	var pts := PackedVector2Array()
	pts.resize(n)
	var hw := PackedFloat32Array()
	hw.resize(n)
	for i in n:
		var c: int = cells[n - 1 - i]
		pts[i] = cell_centre(c % _gw, c / _gw)
		hw[i] = half_width
	p_out.points = pts
	p_out.half_widths = hw
	if not port_unwired(1):
		var surf: PackedFloat32Array = _grids[1]
		var hs := PackedFloat32Array()
		hs.resize(n)
		for i in n:
			var h: float = sample_grid(surf, pts[i].x, pts[i].y)
			hs[i] = 0.0 if not is_finite(h) else h
		p_out.heights = hs


## The cell the walk starts from, or -1 when the field offers none.
func _seed_cell(p_flow: PackedFloat32Array) -> int:
	var best := -1
	var best_v: float = -INF
	if seed_mode == Seed.POINT:
		var dx: float = _rect.size.x / float(maxi(_gw, 1))
		var dz: float = _rect.size.y / float(maxi(_gh, 1))
		var cx := int(floor((seed_point.x - _rect.position.x) / maxf(dx, 1e-6)))
		var cz := int(floor((seed_point.y - _rect.position.y) / maxf(dz, 1e-6)))
		var rx := maxi(int(ceil(seed_radius / maxf(dx, 1e-6))), 0)
		var rz := maxi(int(ceil(seed_radius / maxf(dz, 1e-6))), 0)
		for iz in range(maxi(cz - rz, 0), mini(cz + rz + 1, _gh)):
			for ix in range(maxi(cx - rx, 0), mini(cx + rx + 1, _gw)):
				var v: float = p_flow[iz * _gw + ix]
				if is_finite(v) and v > best_v:
					best_v = v
					best = iz * _gw + ix
	else:
		for i in range(p_flow.size()):
			var v: float = p_flow[i]
			if is_finite(v) and v > best_v:
				best_v = v
				best = i
	# A seed already under the threshold is not a river's mouth, it is dry ground, and tracing from it
	# would emit a one-vertex path the caller then has to recognise as nothing.
	if best >= 0 and best_v < min_flow:
		return -1
	return best


## The unvisited 8-neighbour with the highest accumulation, or -1 when there is none.
##
## Ties break on the lowest cell index — arbitrary, but FIXED, which is the property that matters
## (`nearest-segment-tie-order`): an unspecified tie order is two implementations that agree until the
## day a symmetric fixture makes them disagree.
func _best_neighbour(p_flow: PackedFloat32Array, p_seen: PackedByteArray, p_cell: int) -> int:
	var cx := p_cell % _gw
	var cz := p_cell / _gw
	var best := -1
	var best_v: float = -INF
	for oz in range(-1, 2):
		var z := cz + oz
		if z < 0 or z >= _gh:
			continue
		for ox in range(-1, 2):
			if ox == 0 and oz == 0:
				continue
			var x := cx + ox
			if x < 0 or x >= _gw:
				continue
			var idx := z * _gw + x
			if p_seen[idx] != 0:
				continue
			var v: float = p_flow[idx]
			if is_finite(v) and v > best_v:
				best_v = v
				best = idx
	return best


func _validate_property(p_property: Dictionary) -> void:
	if seed_mode != Seed.POINT and (p_property.name == "seed_point" or p_property.name == "seed_radius"):
		p_property.usage &= ~PROPERTY_USAGE_EDITOR


func node_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if _gw > 0 and port_unwired(0):
		out.append("Path from Flow has no flow field wired, so it produces no path. Wire an Erosion "
				+ "node's `flow` channel into it.")
	elif _out != null and _out.points.size() < 2:
		out.append("Path from Flow traced no river: no cell reached Min Flow. Read the field's range off "
				+ "its preview and lower Min Flow to match — accumulation has no fixed units.")
	return out
