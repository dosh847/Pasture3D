# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphPortTypeGate — the port declarations stay internally consistent, and the machinery that reads them
# (colours, the connection matrix, the native params split) stays in step with the enum.
#
# WHY THIS EXISTS. A port type is read by four separate mechanisms that never talk to each other, and
# every one of them fails QUIETLY when they disagree:
#
#   * the editor colours a socket `PORT_COLORS[type % size]` (PASTURE3D_TERRAIN_GRAPH_GUIDE.md §9), so a
#     type past the end of the table silently borrows another type's colour instead of erroring;
#   * the editor reads `types[r] if r < types.size() else 0`, so a types array shorter than the port count
#     silently makes every port past the end HEIGHT;
#   * GraphEdit permits same-type wires by itself and cross-type wires ONLY where registered, so a type
#     nobody registered connects to nothing — and the author meets that as "I cannot re-make a wire that
#     is already in my graph", long after the commit that caused it;
#   * `native_param_ports()[i] >= 0` says port i carries ONE NUMBER into a params slot, while a field type
#     on the same port says it carries a whole grid. Both cannot be true, and the lowering believes the
#     params map.
#
# The audit that produced this gate found seven ports that had been mis-typed since they were written,
# including a node whose output was drawn HEIGHT-blue while the preview rendered it as a mask. Nothing
# errored. See PASTURE3D_GRAPH_PORT_TYPES_GUIDE.md for what each type means and how to add one.
#
#   [A] no declaration array is shorter than the port count it describes (types, and names)
#   [B] the two output-type declarations cannot disagree — `output_port_type()` is derived, not overridden
#   [C] the field/value split agrees with the native params map, in BOTH directions
#   [D] every PortType member has its own PORT_COLORS entry — the table has not fallen behind the enum
#   [E] every field type the registry actually declares can be wired to every other, through the real
#       matrix in graph_editor.gd — not through a copy of it here
#
# CONTROLS. [A]-[D] are decided by pure predicates that this gate also runs against fabricated BAD
# declarations, so each prints its control alongside its verdict: a criterion that only ever sees healthy
# data cannot tell "all clear" from "I checked nothing". [E]'s control is a type left out of the matrix on
# purpose (FLOAT, a value type, which must NOT be wireable to HEIGHT) — if [E] passed for everything it
# would only be proving that GraphEdit says yes to whatever it is asked.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphPortTypeGate.tscn
extends Node

const GraphEditorScript = preload("res://addons/pasture_3d/src/graph_editor.gd")

## Below this many registered nodes the sweep is not looking at the registry at all.
const MIN_NODES := 60

## The types that carry a grid. Kept in step with `Pasture3DGraphNode.is_field_type` by [C]'s own use of
## that helper — this list is only here to name them in the report.
const FIELD_TYPE_NAMES := ["HEIGHT", "MASK", "FIELD", "SIGNED", "TERRAIN_BUS", "PATH"]

## Ports that break [C] for a reason that is documented and that a retype cannot fix. An entry here is a
## KNOWN DEFECT, not an exemption from the rule: it is printed on every run so it cannot be forgotten, and
## it must name the section of the guide that explains why it stands.
##
##   transform port 1 ('offset') is a VECTOR that feeds no params slot, and `eval_grid` ignores it too. A
##   Vector2 needs two params entries and the map holds one int per port, and the graph bus is scalar
##   floats, so the socket is unrepresentable rather than unfinished. Removing it shifts every later port
##   index down by one and silently rewires saved graphs — a migration, not a retype.
##   PASTURE3D_GRAPH_PORT_TYPES_GUIDE.md §7.
const KNOWN_INERT_PORTS := {"transform": [1]}

var _fail := 0
var _checks := 0


func _ready() -> void:
	print("=== GraphPortTypeGate: the port declarations agree with the machinery that reads them ===\n")
	var nodes := _instantiate_registry()
	_a_no_short_arrays(nodes)
	_b_one_output_declaration(nodes)
	_c_field_value_split(nodes)
	_d_every_type_has_a_colour(nodes)
	_e_field_types_are_wireable(nodes)

	# A criterion that threw before asserting increments nothing, so count completions, not just failures.
	if _checks < 12:
		print("\n    VACUOUS: only %d checks completed; the gate did not measure what it claims to." % _checks)
		_fail += 1
	print("\n=== %s (%d failures, %d checks) ===\n"
			% ["GRAPH PORT TYPE PASS" if _fail == 0 else "GRAPH PORT TYPE FAIL", _fail, _checks])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	_checks += 1
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])


func _instantiate_registry() -> Array:
	var out := []
	for e in Pasture3DGraphNodeRegistry.entries(true):
		var op: StringName = e.get("op", &"")
		var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op)
		if n != null:
			out.append([op, n])
	_check(out.size() >= MIN_NODES, "the registry instantiated %d nodes (>= %d)" % [out.size(), MIN_NODES])
	return out


func _type_name(p_t: int) -> String:
	var names: Dictionary = Pasture3DGraphNode.PortType
	for k in names:
		if int(names[k]) == p_t:
			return String(k)
	return "??(%d)" % p_t


# --- A: no declaration array is shorter than the ports it describes -------------------------------------
# The predicate, so the control can run the same code against data that must fail.
func _short_arrays(p_count: int, p_types_size: int, p_names_size: int) -> bool:
	return p_types_size < p_count or p_names_size < p_count


func _a_no_short_arrays(p_nodes: Array) -> void:
	print("[A] no types or names array is shorter than its port count")
	var bad: Array[String] = []
	var ports := 0
	for pair in p_nodes:
		var n: Pasture3DGraphNode = pair[1]
		ports += n.input_count()
		if _short_arrays(n.input_count(), n.input_port_types().size(), n.input_names().size()):
			bad.append("%s inputs: %d ports, %d types, %d names"
					% [pair[0], n.input_count(), n.input_port_types().size(), n.input_names().size()])
		if n.has_output():
			ports += n.output_count()
			if _short_arrays(n.output_count(), n.output_port_types().size(), n.output_names().size()):
				bad.append("%s outputs: %d ports, %d types, %d names"
						% [pair[0], n.output_count(), n.output_port_types().size(), n.output_names().size()])
	for b in bad:
		print("        " + b)
	_check(bad.is_empty(), "%d declared ports, %d short arrays" % [ports, bad.size()])
	_check(_short_arrays(3, 2, 3) and _short_arrays(3, 3, 1) and not _short_arrays(3, 3, 3),
			"control: the predicate rejects a 2-type/3-port and a 1-name/3-port declaration")


# --- B: the two output declarations cannot disagree ------------------------------------------------------
func _b_one_output_declaration(p_nodes: Array) -> void:
	print("[B] `output_port_type()` is derived from `output_port_types()`, never separately declared")
	var bad: Array[String] = []
	var compared := 0
	for pair in p_nodes:
		var n: Pasture3DGraphNode = pair[1]
		if not n.has_output():
			continue
		var plural := n.output_port_types()
		if plural.is_empty():
			continue
		compared += 1
		if n.output_port_type() != int(plural[0]):
			bad.append("%s: output_port_type()=%s but output_port_types()[0]=%s"
					% [pair[0], _type_name(n.output_port_type()), _type_name(int(plural[0]))])
	for b in bad:
		print("        " + b)
	_check(compared >= MIN_NODES / 2, "compared %d nodes that declare an output type" % compared)
	_check(bad.is_empty(), "%d disagreements" % bad.size())
	# The control is a node that DOES override the singular, which is what this criterion forbids. It is
	# the only way to show the comparison would notice; every shipped node inherits the derivation.
	var rogue := _RogueSingular.new()
	_check(rogue.output_port_type() != int(rogue.output_port_types()[0]),
			"control: a node overriding output_port_type() is detected as a disagreement")


class _RogueSingular extends Pasture3DGraphNode:
	func output_port_types() -> PackedInt32Array:
		return PackedInt32Array([PortType.MASK])

	func output_port_type() -> int:
		return PortType.HEIGHT


# --- C: the field/value split agrees with the native params map -------------------------------------------
# A port is a VALUE port iff it feeds a params slot. This is the invariant the lowering depends on, and it
# has to hold in both directions: a field type on a params slot lowers a grid into one float, and a value
# type on a non-params port means the evaluator is handed a grid the node reads as `p_inputs[i][0]`.
func _c_field_value_split(p_nodes: Array) -> void:
	print("[C] a port declares a field type iff it is NOT a native params slot")
	var bad: Array[String] = []
	var known: Array[String] = []
	var compared := 0
	for pair in p_nodes:
		var n: Pasture3DGraphNode = pair[1]
		var types := n.input_port_types()
		var pmap := n.native_param_ports()
		# A node that blocks the native path declares no params map at all; there is nothing to agree with.
		if pmap.is_empty():
			continue
		for i in range(mini(n.input_count(), mini(types.size(), pmap.size()))):
			compared += 1
			var is_field := Pasture3DGraphNode.is_field_type(int(types[i]))
			var is_slot: bool = int(pmap[i]) >= 0
			if is_field and is_slot:
				bad.append("%s port %d ('%s') is params slot %d but declares field type %s"
						% [pair[0], i, n.input_names()[i] if i < n.input_names().size() else "",
						int(pmap[i]), _type_name(int(types[i]))])
			elif not is_field and not is_slot:
				if (KNOWN_INERT_PORTS.get(String(pair[0]), []) as Array).has(i):
					known.append("%s port %d ('%s') declares %s and drives nothing — guide §7"
							% [pair[0], i, n.input_names()[i] if i < n.input_names().size() else "",
							_type_name(int(types[i]))])
					continue
				bad.append("%s port %d ('%s') declares value type %s but feeds no params slot"
						% [pair[0], i, n.input_names()[i] if i < n.input_names().size() else "",
						_type_name(int(types[i]))])
	for b in bad:
		print("        " + b)
	for k in known:
		print("        KNOWN  " + k)
	_check(compared >= 100, "compared %d ports that have both a type and a params entry" % compared)
	_check(bad.is_empty(), "%d contradictions, %d known and documented" % [bad.size(), known.size()])
	# An allowlist that stops matching anything is an allowlist nobody will ever delete. Fail if the known
	# defect has been fixed, so the entry goes with the fix rather than outliving it.
	_check(known.size() == 1, "the one known inert port is still present (found %d)" % known.size())
	_check(Pasture3DGraphNode.is_field_type(Pasture3DGraphNode.PortType.FIELD)
			and Pasture3DGraphNode.is_field_type(Pasture3DGraphNode.PortType.SIGNED)
			and not Pasture3DGraphNode.is_field_type(Pasture3DGraphNode.PortType.FLOAT)
			and not Pasture3DGraphNode.is_field_type(Pasture3DGraphNode.PortType.INT),
			"control: is_field_type accepts FIELD/SIGNED and rejects FLOAT/INT")


# --- D: every type has its own colour ---------------------------------------------------------------------
func _d_every_type_has_a_colour(p_nodes: Array) -> void:
	print("[D] PORT_COLORS has an entry for every PortType member, and for every declared type")
	var colours: int = GraphEditorScript.PORT_COLORS.size()
	var members: Dictionary = Pasture3DGraphNode.PortType
	var highest := -1
	for k in members:
		highest = maxi(highest, int(members[k]))
	_check(colours == members.size() and highest == members.size() - 1,
			"%d colours for %d enum members, highest value %d" % [colours, members.size(), highest])

	var uncoloured: Array[String] = []
	var seen := {}
	for pair in p_nodes:
		var n: Pasture3DGraphNode = pair[1]
		var all := Array(n.input_port_types()) + Array(n.output_port_types())
		for t in all:
			seen[int(t)] = true
			if _uncoloured(colours, int(t)):
				uncoloured.append("%s declares type %d" % [pair[0], int(t)])
	for u in uncoloured:
		print("        " + u)
	_check(uncoloured.is_empty(), "%d distinct types declared across the registry, %d without a colour"
			% [seen.size(), uncoloured.size()])
	# `PORT_COLORS[t % size]` is why an out-of-range type is invisible rather than loud: it wraps onto an
	# existing colour instead of erroring, so the range test above is the only thing standing between a new
	# enum member and a socket wearing another type's colour.
	_check(_uncoloured(colours, colours) and _uncoloured(colours, -1) and not _uncoloured(colours, colours - 1),
			"control: the range test rejects type %d and type -1, and accepts %d" % [colours, colours - 1])


## True when p_type has no colour of its own. Shared by the sweep and its control.
func _uncoloured(p_colours: int, p_type: int) -> bool:
	return p_type < 0 or p_type >= p_colours


# --- E: the field types the registry declares are mutually wireable ----------------------------------------
func _e_field_types_are_wireable(p_nodes: Array) -> void:
	print("[E] every scalar field type declared in the registry can be wired to every other")
	var ge := GraphEdit.new()
	add_child(ge)
	GraphEditorScript.register_connection_types(ge)

	# Only the types the registry ACTUALLY declares — an enum member nobody uses yet is not a broken wire.
	var declared := {}
	for pair in p_nodes:
		for t in Array(pair[1].output_port_types()):
			declared[int(t)] = true
	var scalars: Array[int] = []
	for t in declared:
		if Pasture3DGraphNode.is_field_type(t) and t != Pasture3DGraphNode.PortType.PATH \
				and t != Pasture3DGraphNode.PortType.TERRAIN_BUS:
			scalars.append(t)
	scalars.sort()

	var missing: Array[String] = []
	var pairs := 0
	for a in scalars:
		for b in scalars:
			pairs += 1
			if not ge.is_valid_connection_type(a, b):
				missing.append("%s -> %s is refused" % [_type_name(a), _type_name(b)])
	for m in missing:
		print("        " + m)
	_check(scalars.size() >= 4, "the registry declares %d scalar field output types: %s"
			% [scalars.size(), ", ".join(scalars.map(func(t): return _type_name(t)))])
	_check(missing.is_empty(), "%d ordered pairs, %d refused" % [pairs, missing.size()])
	# Without this the criterion would pass on a GraphEdit that accepts everything.
	_check(not ge.is_valid_connection_type(Pasture3DGraphNode.PortType.FLOAT,
					Pasture3DGraphNode.PortType.HEIGHT)
			and not ge.is_valid_connection_type(Pasture3DGraphNode.PortType.PATH,
					Pasture3DGraphNode.PortType.HEIGHT),
			"control: FLOAT -> HEIGHT and PATH -> HEIGHT are still refused")
	ge.queue_free()
