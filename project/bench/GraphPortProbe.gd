# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphPortProbe — which node PROPERTY drives each input port's unwired value, found by moving every
# property and watching the public accessors. PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §6.3.
#
# The golden port table (`GraphPortTable.gd`) is taken on a default-constructed node, so it cannot tell
# `return amount` from `return 1.0` when `amount` defaults to 1.0. This can: it sets each script property
# to a different value and records which ports' `input_unwired_default` followed it, and whether any
# OTHER row of the node's port table moved (a port whose name or type depends on a property).
#
# Output is one JSON object keyed by script, written to the path given after `--`:
#   { script: { "follows": { port: [properties] }, "complex": { port: [properties] }, "shape": [properties],
#               "defaults": [text] } }
# `follows`  the port's unwired value equals float(property) after the move.
# `complex`  the port's unwired value moved but is not the property itself (Gradient's `start.x`).
# `shape`    some non-default row of the port table moved.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project --script bench/GraphPortProbe.gd -- <out.json>
extends SceneTree

const Table := preload("res://bench/GraphPortTable.gd")


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("GraphPortProbe: pass the output path after --")
		quit(1)
		return
	var out := {}
	for path in Table.node_scripts():
		var s := load(path) as GDScript
		if s == null or not s.can_instantiate():
			continue
		var key: String = path.get_file().get_basename()
		out[key] = _probe(s)
	var f := FileAccess.open(args[0], FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "\t", true))
	f.close()
	print("GraphPortProbe: %d scripts -> %s" % [out.size(), args[0]])
	quit(0)


func _probe(p_script: GDScript) -> Dictionary:
	var follows := {}
	var complex := {}
	var shape: Array = []
	var base: Pasture3DGraphNode = p_script.new()
	var base_shape := _shape_rows(base)
	var base_defaults := _defaults(base)
	for prop in base.get_property_list():
		if not (int(prop.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var pname: String = prop.name
		if pname.begins_with("_"):
			continue
		for candidate in _moves(base.get(pname)):
			var n: Pasture3DGraphNode = p_script.new()
			n.set(pname, candidate)
			var now = n.get(pname)
			if typeof(now) != typeof(candidate) or now == base.get(pname):
				continue
			if _shape_rows(n) != base_shape and not shape.has(pname):
				shape.append(pname)
			var d := _defaults(n)
			for i in range(mini(d.size(), base_defaults.size())):
				if _same(d[i], base_defaults[i]):
					continue
				var scalar: bool = typeof(now) == TYPE_FLOAT or typeof(now) == TYPE_INT or typeof(now) == TYPE_BOOL
				if scalar and _same(d[i], float(now)):
					# A list: a node may keep a legacy alias whose setter writes the real property.
					var f: Array = follows.get(str(i), [])
					if not f.has(pname):
						f.append(pname)
					follows[str(i)] = f
				else:
					var arr: Array = complex.get(str(i), [])
					if not arr.has(pname):
						arr.append(pname)
					complex[str(i)] = arr
	# A port that follows one property outright is not also "complex" on that property.
	for k in follows.keys():
		if complex.has(k):
			var rest: Array = complex[k].filter(func(p): return not follows[k].has(p))
			if rest.is_empty():
				complex.erase(k)
			else:
				complex[k] = rest
	shape.sort()
	# The golden table rounds defaults to six places; these are the same numbers unrounded.
	var exact: Array = []
	for v in base_defaults:
		exact.append(str(v))
	return {"follows": follows, "complex": complex, "shape": shape, "defaults": exact}


func _moves(p_v) -> Array:
	match typeof(p_v):
		TYPE_FLOAT:
			return [p_v + 0.37, p_v - 0.37, p_v * 0.5 + 0.011]
		TYPE_INT:
			return [p_v + 1, p_v - 1, p_v + 2]
		TYPE_BOOL:
			return [not p_v]
		TYPE_VECTOR2:
			return [p_v + Vector2(0.37, 0.0), p_v + Vector2(0.0, 0.37)]
		TYPE_VECTOR3:
			return [p_v + Vector3(0.37, 0.0, 0.0), p_v + Vector3(0.0, 0.37, 0.0), p_v + Vector3(0.0, 0.0, 0.37)]
	return []


func _defaults(p_n: Pasture3DGraphNode) -> Array:
	var out: Array = []
	for i in range(p_n.input_count()):
		out.append(p_n.input_unwired_default(i))
	return out


## Every table row with the per-port default column blanked.
func _shape_rows(p_n: Pasture3DGraphNode) -> PackedStringArray:
	var out := PackedStringArray()
	for row in Table.rows_of("n", p_n):
		var parts := row.split("|")
		if parts.size() > 5 and parts[1] == "in":
			parts[5] = "*"
		out.append("|".join(parts))
	return out


func _same(p_a: float, p_b: float) -> bool:
	if is_nan(p_a) or is_nan(p_b):
		return is_nan(p_a) and is_nan(p_b)
	return is_equal_approx(p_a, p_b)
