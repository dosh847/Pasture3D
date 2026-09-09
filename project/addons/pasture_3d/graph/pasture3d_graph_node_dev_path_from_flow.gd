# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeDevPathFromFlow — the ORACLE for Path from Flow. Pure GDScript, hidden.
#
# See PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md §1 & §3.2.
# The production node calls Pasture3DUtil.path_from_flow_solve and fails fast without it.
@tool
class_name Pasture3DGraphNodeDevPathFromFlow
extends Pasture3DGraphNodePathDerive

enum Seed { OUTLET, POINT }

@export var seed_mode: Seed = Seed.OUTLET:
	set(v):
		seed_mode = v
		emit_changed()
		notify_property_list_changed()

@export var seed_point: Vector2 = Vector2.ZERO:
	set(v):
		seed_point = v
		emit_changed()

@export_range(0.0, 500.0, 0.5, "or_greater", "suffix:m") var seed_radius: float = 20.0:
	set(v):
		seed_radius = maxf(v, 0.0)
		emit_changed()

@export_range(0.0, 10000.0, 0.001, "or_greater") var min_flow: float = 0.05:
	set(v):
		min_flow = maxf(v, 0.0)
		emit_changed()

@export_range(1, 32, 1) var step_cells: int = 2:
	set(v):
		step_cells = maxi(v, 1)
		emit_changed()

@export_range(8, 4096, 1) var max_points: int = 512:
	set(v):
		max_points = maxi(v, 8)
		emit_changed()

@export_range(0.0, 200.0, 0.01, "or_greater", "suffix:m") var half_width: float = 4.0:
	set(v):
		half_width = maxf(v, 0.0)
		emit_changed()


func op() -> StringName:
	return &"dev_path_from_flow"


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


func input_unwired_default(_p_port: int) -> float:
	return NAN


func derive_without_grid(_p_src: Pasture3DGraphPath) -> Pasture3DGraphPath:
	return null


func _derive_path(p_inputs: Array) -> Pasture3DGraphPath:
	var made := super(p_inputs)
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
			break
		cells.append(cur)

	var n := cells.size()
	if n < 2:
		return
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
	if best >= 0 and best_v < min_flow:
		return -1
	return best


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
