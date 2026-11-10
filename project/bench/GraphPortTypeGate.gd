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
#   [F] every declared output type reaches some declared input type and can be dragged off its socket
#   [G] no two port colours are near-identical (SIGNED used to share COLOR's magenta)
#   [H] DLA's coverage and detail_size ports reach the growth when wired
#   [I] no field type connects to a value type (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §8, criterion A)
#   [J] the constants and both Measure outputs drive a FLOAT port; a Noise does not (§8 B)
#   [K] a field-to-value wire a graph already holds warns, survives a save, and evaluates as before (§8 C)
#   [L] the editor offers Insert Measure for exactly that drop, and value ports draw a diamond
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
const FIELD_TYPE_NAMES := ["HEIGHT", "MASK", "FIELD", "SIGNED", "PATH"]

## Ports that break [C] for a reason that is documented and that a retype cannot fix. An entry here is a
## KNOWN DEFECT, not an exemption from the rule: it is printed on every run so it cannot be forgotten, and
## it must name the section of the guide that explains why it stands.
##
##
##   EMPTY since 2026-11-09. It held Transform's `offset` and Export Normal Map's `normal`, two VECTOR
##   inputs nothing could drive; both went when wires were stored by port id and removing a port stopped
##   re-aiming the ones after it (PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §7.3).
const KNOWN_INERT_PORTS := {}

## Every `_check` call on a healthy run. A criterion that throws part-way leaves the count short.
const EXPECTED_CHECKS := 47

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
	_f_every_output_reaches_an_input(nodes)
	_g_type_colours_distinct()
	_h_dla_reads_its_ports()
	_i_no_field_into_value()
	_j_values_drive_a_float_port()
	_k_stored_field_to_value_wire()
	_l_insert_measure()

	# A criterion that threw before asserting increments nothing, so count completions, not just failures.
	if _checks != EXPECTED_CHECKS:
		print("\n    VACUOUS: %d checks completed, expected %d; the gate did not measure what it claims to."
				% [_checks, EXPECTED_CHECKS])
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
	func _outputs() -> Array[Pasture3DGraphPort]:
		return [Pasture3DGraphPort.field(&"out", PortType.MASK)]

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
	_check(known.size() == KNOWN_INERT_PORTS.size(), "every listed inert port is still present (found %d of %d)"
			% [known.size(), KNOWN_INERT_PORTS.size()])
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
		if Pasture3DGraphNode.is_field_type(t) and t != Pasture3DGraphNode.PortType.PATH:
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
	# FLOAT -> HEIGHT used to be half of this control. It became a legal wire when Const Float was retyped
	# (a constant is a flat field), so the control now uses types that must still be refused.
	_check(not ge.is_valid_connection_type(Pasture3DGraphNode.PortType.COLOR,
					Pasture3DGraphNode.PortType.HEIGHT)
			and not ge.is_valid_connection_type(Pasture3DGraphNode.PortType.PATH,
					Pasture3DGraphNode.PortType.HEIGHT),
			"control: COLOR -> HEIGHT and PATH -> HEIGHT are still refused")
	ge.queue_free()


# --- F: every declared output type can reach some declared input type, and can be dragged off -------------
## Output types with no possible consumer, and why. EMPTY since 2026-11-09: it held CURVE, for Const Curve,
## which was removed with the type.
const KNOWN_UNREACHABLE_OUTPUTS := {}

func _f_every_output_reaches_an_input(p_nodes: Array) -> void:
	print("[F] every declared output type connects to at least one declared input type, and right-disconnects")
	var ge := GraphEdit.new()
	add_child(ge)
	GraphEditorScript.register_connection_types(ge)
	var outs := {}
	var ins := {}
	for pair in p_nodes:
		for t in Array(pair[1].output_port_types()):
			outs[int(t)] = true
		for t in Array(pair[1].input_port_types()):
			ins[int(t)] = true
	var dead: Array[String] = []
	var known: Array[String] = []
	for o in outs:
		var reach := false
		for i in ins:
			if o == i or ge.is_valid_connection_type(o, i):
				reach = true
				break
		if not reach:
			if KNOWN_UNREACHABLE_OUTPUTS.has(_type_name(o)):
				known.append("%s — %s" % [_type_name(o), KNOWN_UNREACHABLE_OUTPUTS[_type_name(o)]])
			else:
				dead.append(_type_name(o))
	for k in known:
		print("        KNOWN  " + k)
	_check(dead.is_empty(), "%d output types, unreachable: %s" % [outs.size(), ", ".join(dead)])
	_check(known.size() == KNOWN_UNREACHABLE_OUTPUTS.size(),
			"every listed unreachable output type is still present (found %d of %d)"
			% [known.size(), KNOWN_UNREACHABLE_OUTPUTS.size()])
	_check(ge.is_valid_connection_type(Pasture3DGraphNode.PortType.BOOL, Pasture3DGraphNode.PortType.FLOAT)
			and ge.is_valid_connection_type(Pasture3DGraphNode.PortType.FLOAT, Pasture3DGraphNode.PortType.SIGNED),
			"BOOL -> FLOAT and FLOAT -> SIGNED are accepted (Const Bool and Const Float can drive a Salève dx)")
	# GraphEdit has no getter for right-disconnect types, so that registration is checked by reading the
	# real function's source for every value type that shipped without one.
	var src: String = (GraphEditorScript as Script).source_code
	var body := src.substr(src.find("static func register_connection_types"))
	body = body.substr(0, body.find("\nfunc ", 10) if body.find("\nfunc ", 10) > 0 else body.length())
	_check(body.contains("add_valid_right_disconnect_type(Pasture3DGraphNode.PortType.COLOR)"),
			"COLOR outputs are registered for right-disconnect (BOOL via the scalar value loop)")
	# Control: an empty GraphEdit reaches nothing, so the sweep would notice a missing registration.
	var bare := GraphEdit.new()
	_check(not bare.is_valid_connection_type(Pasture3DGraphNode.PortType.BOOL, Pasture3DGraphNode.PortType.FLOAT),
			"control: an unregistered GraphEdit refuses BOOL -> FLOAT")
	bare.free()
	ge.queue_free()


# --- G: no two type colours are near-identical -------------------------------------------------------------
## 0.3, because the clash an author actually reported (magenta SIGNED beside pink COLOR) was 0.29 apart.
const MIN_COLOUR_DISTANCE := 0.3

func _colour_clashes(p_colours: Array) -> Array[String]:
	var out: Array[String] = []
	for a in range(p_colours.size()):
		for b in range(a + 1, p_colours.size()):
			var ca: Color = p_colours[a]
			var cb: Color = p_colours[b]
			if Vector3(ca.r - cb.r, ca.g - cb.g, ca.b - cb.b).length() < MIN_COLOUR_DISTANCE:
				out.append("%s ~ %s" % [_type_name(a), _type_name(b)])
	return out

func _g_type_colours_distinct() -> void:
	print("[G] every pair of port colours is at least %.2f apart in RGB" % MIN_COLOUR_DISTANCE)
	var clashes := _colour_clashes(Array(GraphEditorScript.PORT_COLORS))
	_check(clashes.is_empty(), "clashing pairs: %s" % ", ".join(clashes))
	var old: Array = []
	for c in GraphEditorScript.PORT_COLORS:
		old.append(c)
	old[11] = Color(0.85, 0.35, 0.75) # the SIGNED colour before this fix
	_check(not _colour_clashes(old).is_empty(), "control: the old magenta SIGNED is caught (%s)" % ", ".join(_colour_clashes(old)))


# --- H: DLA's coverage and detail_size ports change the result when wired ---------------------------------
func _h_dla_reads_its_ports() -> void:
	print("[H] a wired DLA coverage / detail_size reaches the growth")
	var d: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"dla")
	if d == null:
		_check(false, "dla did not instantiate")
		return
	# LIVE: a FROZEN solver serves its first cache and only flags a key change as stale, by design, so a
	# frozen node would pass the control and fail the criterion whether or not the ports were read.
	d.set("evaluation", Pasture3DGraphSolverNode.Evaluation.LIVE)
	var gw := 48
	var n := gw * gw
	var surf := PackedFloat32Array(); surf.resize(n)
	var rect := Rect2(0, 0, 256, 256)
	var un: PackedFloat32Array = d.eval_grid([surf], gw, gw, null, rect)
	var wired: PackedFloat32Array = d.eval_grid([surf, PackedFloat32Array([float(d.get("amplitude"))]),
			PackedFloat32Array([0.3]), PackedFloat32Array([0.4])], gw, gw, null, rect)
	var same_as_props: PackedFloat32Array = d.eval_grid([surf, PackedFloat32Array([float(d.get("amplitude"))]),
			PackedFloat32Array([float(d.get("coverage"))]), PackedFloat32Array([float(d.get("detail_size"))])], gw, gw, null, rect)
	_check(wired != un, "wiring coverage 0.3 / detail 0.4 changes the massif")
	_check(same_as_props == un, "control: wiring the property values reproduces the unwired massif")


# --- I: no field type connects to a value type ------------------------------------------------------------
const SCALAR_FIELDS: Array[int] = [Pasture3DGraphNode.PortType.HEIGHT, Pasture3DGraphNode.PortType.MASK,
		Pasture3DGraphNode.PortType.FIELD, Pasture3DGraphNode.PortType.SIGNED]
const VALUES: Array[int] = [Pasture3DGraphNode.PortType.FLOAT, Pasture3DGraphNode.PortType.INT,
		Pasture3DGraphNode.PortType.BOOL]

func _i_no_field_into_value() -> void:
	print("[I] no field type connects to a value type, in the editor's matrix and in the model's")
	var ge := GraphEdit.new()
	add_child(ge)
	GraphEditorScript.register_connection_types(ge)
	var open: Array[String] = []
	var closed: Array[String] = []
	var disagree := 0
	for f in SCALAR_FIELDS:
		for v in VALUES:
			if ge.is_valid_connection_type(f, v):
				open.append("%s -> %s" % [_type_name(f), _type_name(v)])
			if not ge.is_valid_connection_type(v, f):
				closed.append("%s -> %s" % [_type_name(v), _type_name(f)])
			if ge.is_valid_connection_type(f, v) != Pasture3DGraphNode.can_connect(f, v) \
					or ge.is_valid_connection_type(v, f) != Pasture3DGraphNode.can_connect(v, f):
				disagree += 1
	_check(open.is_empty(), "%d field -> value pairs, accepted: %s" % [SCALAR_FIELDS.size() * VALUES.size(), ", ".join(open)])
	_check(closed.is_empty(), "control: all %d value -> field pairs still connect (refused: %s)"
			% [SCALAR_FIELDS.size() * VALUES.size(), ", ".join(closed)])
	_check(disagree == 0, "the editor's matrix and can_connect agree on all %d pairs" % (2 * SCALAR_FIELDS.size() * VALUES.size()))
	ge.queue_free()


# --- J: the value sources drive a FLOAT port, a field source does not ---------------------------------------
## A Noise that produces something: the node has no FastNoiseLite until it is given one, and reads 0.
func _noise(p_seed: int, p_amplitude: float) -> Pasture3DGraphNode:
	var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"noise")
	var fnl := FastNoiseLite.new()
	fnl.seed = p_seed
	n.set("noise", fnl)
	n.set("amplitude", p_amplitude)
	return n


## Transform, with `p_source` (an op) beside it. Returns [graph, source index, transform index, rotation port].
func _transform_graph(p_source: StringName) -> Array:
	var g := Pasture3DTerrainGraph.create_empty()
	var base := g.add_node(_noise(11, 40.0))
	var src := g.add_node(_noise(7, 25.0) if p_source == &"noise" else Pasture3DGraphNodeRegistry.create(p_source))
	var tr := g.add_node(Pasture3DGraphNodeRegistry.create(&"transform"))
	var out := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"))
	g.connect_ports(base, 0, tr, 0)
	g.connect_ports(tr, 0, out, 0)
	g.set_output(out)
	return [g, src, tr, g.nodes[tr].input_index_of(&"rotation")]


func _j_values_drive_a_float_port() -> void:
	print("[J] Const Float, Const Int, Const Bool and both Measure outputs connect to a FLOAT port")
	var probe := _transform_graph(&"const")
	var rot: int = probe[3]
	_check(rot > 0 and probe[0].nodes[probe[2]].input_ports()[rot].type == Pasture3DGraphNode.PortType.FLOAT,
			"Transform's `rotation` is input %d and is FLOAT" % rot)
	var refused: Array[String] = []
	var made := 0
	for src in [[&"const", 0], [&"const_int", 0], [&"const_bool", 0], [&"measure", 0], [&"measure", 1]]:
		var p := _transform_graph(src[0])
		if p[0].connect_ports(p[1], src[1], p[2], rot):
			made += 1
		else:
			refused.append("%s:%d" % [src[0], src[1]])
	_check(refused.is_empty(), "%d of 5 value outputs connected (refused: %s)" % [made, ", ".join(refused)])
	var n := _transform_graph(&"noise")
	var before: int = n[0].connections.size()
	var ok: bool = n[0].connect_ports(n[1], 0, n[2], rot)
	_check(not ok and n[0].connections.size() == before,
			"control: a Noise output into `rotation` is refused and stores nothing (returned %s)" % str(ok))
	# ... and the refusal is about the port, not about that Noise: the same output into the field port goes in.
	_check(n[0].connect_ports(n[1], 0, n[2], 0), "control: the same Noise output connects to Transform's field input")


# --- K: a stored field-to-value wire warns, survives, and evaluates as before -------------------------------
func _cell_zero_warnings(p_graph: Pasture3DTerrainGraph) -> Array[String]:
	var out: Array[String] = []
	for w in p_graph.graph_warnings():
		if w.contains("cell 0"):
			out.append(w)
	return out


func _k_stored_field_to_value_wire() -> void:
	print("[K] a field-to-value wire the graph already holds warns, is kept, and evaluates as before")
	var gw := 48
	# Off the origin: gradient noise is exactly 0 on its lattice, and a cell 0 of 0 is the unwired rotation.
	# The first run of this criterion found that out by failing "the wire is live".
	var rect := Rect2(37.3, 91.7, 256, 256)
	# The stored wire: assigned through `connections`, which is how a graph saved before this rule holds it.
	var p := _transform_graph(&"noise")
	var g: Pasture3DTerrainGraph = p[0]
	var src: int = p[1]
	var tr: int = p[2]
	var rot: int = p[3]
	var unwired: PackedFloat32Array = g.evaluate(gw, gw, rect)
	var arr: Array = g.connections.duplicate()
	arr.append(PackedInt32Array([src, 0, tr, rot]))
	g.connections = arr
	var warns := _cell_zero_warnings(g)
	for w in warns:
		print("        " + w)
	_check(warns.size() == 1 and warns[0].contains(g.nodes[tr].display_name()) and warns[0].contains("rotation"),
			"one warning, naming the node and the port (%d found)" % warns.size())

	# "As before" is cell 0 of the source: the same graph with a Const holding that number in its place.
	var cell0: float = g.evaluate(gw, gw, rect, null, null, src)[0]
	_check(absf(cell0) > 1.0, "the source's cell 0 is a real rotation, %.4f degrees" % cell0)
	var wired: PackedFloat32Array = g.evaluate(gw, gw, rect)
	var c := _transform_graph(&"const")
	var cg: Pasture3DTerrainGraph = c[0]
	cg.nodes[c[1]].set("value", cell0)
	cg.connect_ports(c[1], 0, c[2], rot)
	var with_const: PackedFloat32Array = cg.evaluate(gw, gw, rect)
	_check(wired == with_const and wired.size() == gw * gw,
			"it evaluates to what a Const of the source's cell 0 (%.4f) gives, bit for bit" % cell0)
	_check(wired != unwired, "the wire is live: the result differs from the unwired graph")
	_check(_cell_zero_warnings(cg).is_empty(), "control: the graph with the Const in its place does not warn")

	# Kept, not dropped: through a save and a load, and through a copy.
	var path := "user://graph_port_type_gate_k.tres"
	ResourceSaver.save(g, path)
	var back: Pasture3DTerrainGraph = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_check(back != null and back.connections.size() == g.connections.size() and _cell_zero_warnings(back).size() == 1,
			"saved and reloaded, the wire is still there and still warns (%d of %d wires)"
			% [back.connections.size() if back != null else -1, g.connections.size()])
	var before := g.connections.size()
	g.duplicate_subgraph([src, tr])
	_check(g.connections.size() == before + 1 and _cell_zero_warnings(g).size() == 2,
			"duplicating the two nodes copies the wire between them (%d -> %d wires)" % [before, g.connections.size()])


# --- L: Insert Measure, and the diamond -----------------------------------------------------------------
func _l_insert_measure() -> void:
	print("[L] the editor offers Insert Measure for a field dropped on a value port, and inserts it")
	var p := _transform_graph(&"noise")
	var g: Pasture3DTerrainGraph = p[0]
	var src: int = p[1]
	var tr: int = p[2]
	var rot: int = p[3]
	var konst := g.add_node(Pasture3DGraphNodeRegistry.create(&"const"))
	var ed := Pasture3DGraphEditor.new()
	add_child(ed)
	ed._build_ui()
	ed.graph = g
	ed._rebuild()
	_check(ed.measure_offer(src, 0, tr, rot), "a Noise output onto `rotation` is offered a Measure")
	_check(not ed.measure_offer(konst, 0, tr, rot) and not ed.measure_offer(src, 0, tr, 0)
			and not ed.measure_offer(src, 0, tr, 99),
			"control: a Const onto `rotation`, a Noise onto the field input and a port that does not exist are not")

	var gn := ed._graphedit.get_node_or_null("n%d" % tr) as GraphNode
	_check(gn != null and gn.get_slot_custom_icon_left(rot) != null and gn.get_slot_custom_icon_left(0) == null,
			"Transform draws a diamond on `rotation` and the default circle on its field input")
	var kn := ed._graphedit.get_node_or_null("n%d" % konst) as GraphNode
	var sn := ed._graphedit.get_node_or_null("n%d" % src) as GraphNode
	_check(kn != null and sn != null and kn.get_slot_custom_icon_right(0) != null and sn.get_slot_custom_icon_right(0) == null,
			"a Const's output is a diamond and a Noise's is a circle")

	var nodes_before := g.nodes.size()
	var wires_before := g.connections.size()
	ed._action_insert_measure(src, 0, tr, rot)
	var m := nodes_before
	var is_measure: bool = g.nodes.size() == nodes_before + 1 and g.nodes[m] is Pasture3DGraphNodeMeasure
	var a := false
	var b := false
	for c in g.connections:
		if int(c[0]) == src and int(c[1]) == 0 and int(c[2]) == m and int(c[3]) == 0:
			a = true
		if int(c[0]) == m and int(c[1]) == 0 and int(c[2]) == tr and int(c[3]) == rot:
			b = true
	_check(is_measure and a and b and g.connections.size() == wires_before + 2,
			"it adds one Measure wired Noise -> in and min -> rotation (%d -> %d nodes, %d -> %d wires)"
			% [nodes_before, g.nodes.size(), wires_before, g.connections.size()])
	_check(_cell_zero_warnings(g).is_empty(), "and the graph has no cell-0 warning")
	ed._get_undo_redo().undo()
	_check(g.nodes.size() == nodes_before and g.connections.size() == wires_before,
			"one undo removes the Measure and both wires (%d nodes, %d wires)" % [g.nodes.size(), g.connections.size()])
	# Control: asked for a wire that is legal as it stands, the action does nothing.
	ed._action_insert_measure(konst, 0, tr, rot)
	_check(g.nodes.size() == nodes_before, "control: Insert Measure on a Const -> rotation pair adds nothing")
	ed.queue_free()
