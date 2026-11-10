# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphPortDescriptorGate — a node declares each port ONCE, and everything else is derived from that.
# PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §6 (P2).
#
#   [A] the derived port table equals the golden one taken before the migration, and a port that reads a
#       property follows it AFTER the ports were first read (the cache is not a snapshot);
#   [B] every registered node compiles to the same native program as before the migration;
#   [C] port ids are unique within a node's inputs and within its outputs;
#   [D] every property a port names exists on its node;
#   [E] `connect_ports` refuses a wire the type matrix refuses and leaves `connections` untouched, and
#       `graph_warnings` reports one that is already stored;
#   [F] only a port declared required warns when unwired;
#   [G] the editor's registered connection types are exactly `Pasture3DGraphNode.can_connect`.
#
# Every criterion carries a control that must fail, on the same code path.
#
# `_ran` counts sub-cases that reached their assert. A GDScript error aborts the function it is in without
# failing anything, so a criterion that threw would otherwise read as a pass.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/GraphPortDescriptorGate.tscn
extends Node

const Table := preload("res://bench/GraphPortTable.gd")
const Programs := preload("res://bench/GraphPortPrograms.gd")
const PT := Pasture3DGraphNode.PortType
const EXPECTED_RAN := 39 # [A] 3 + 8, [B] 4, [C] 3, [D] 3, [E] 9, [F] 5, [G] 4

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("\n=== GraphPortDescriptorGate: one declaration per port (ports spec P2) ===\n")
	_a_table_equals_golden()
	_a_ports_follow_their_properties()
	_b_programs_equal_golden()
	_c_ids_are_unique()
	_d_properties_exist()
	_e_connect_refuses()
	_f_only_required_ports_warn()
	_g_editor_matrix_is_can_connect()
	print("\n    sub-cases that reached their assert: %d (want %d)" % [_ran, EXPECTED_RAN])
	if _ran != EXPECTED_RAN:
		_fail += 1; print("    !! a criterion stopped early — a script error aborted it, or the count is stale")
	print("\n=== %s (%d failures) ===\n" % ["GRAPH PORT DESCRIPTOR PASS" if _fail == 0 else "GRAPH PORT DESCRIPTOR FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	_ran += 1
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])


func _golden(p_path: String) -> PackedStringArray:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return PackedStringArray()
	var rows := f.get_as_text().split("\n")
	while rows.size() > 0 and rows[rows.size() - 1] == "":
		rows.remove_at(rows.size() - 1)
	return rows


## The rows of `p_a` that are not, at the same position, in `p_b` — and a length difference as one row.
func _diff(p_a: PackedStringArray, p_b: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	if p_a.size() != p_b.size():
		out.append("row count %d vs %d" % [p_a.size(), p_b.size()])
	for i in range(mini(p_a.size(), p_b.size())):
		if p_a[i] != p_b[i]:
			out.append("%s  !=  %s" % [p_a[i], p_b[i]])
	return out


# ---- [A] -------------------------------------------------------------------------------------------

func _a_table_equals_golden() -> void:
	print("[A] the derived port table equals the golden one")
	var golden := _golden(Table.GOLDEN)
	var now := Table.table()
	_check(golden.size() > 1000, "the golden table has %d rows (160 scripts' worth)" % golden.size())
	var d := _diff(now, golden)
	_check(d.is_empty(), "%d rows, identical%s" % [now.size(), "" if d.is_empty() else " — " + "; ".join(d.slice(0, 8))])
	# CONTROL. One golden row altered — a port's type — is one difference, found.
	var altered := golden.duplicate()
	var at := -1
	for i in range(altered.size()):
		if altered[i].begins_with("pasture3d_graph_node_contrast|in|1|"):
			at = i
			break
	if at >= 0:
		altered[at] = altered[at].replace("|amount|4|", "|amount|1|")
	_check(at >= 0 and _diff(now, altered).size() == 1, "control: one altered golden row is one reported difference")


func _a_ports_follow_their_properties() -> void:
	print("\n[A] a port that reads a property follows it after the ports were first read")
	# Each of these builds a descriptor from a property inside `_inputs()` / `_outputs()`. The table above
	# is taken on a fresh node, so it cannot see a cache that never refreshes; these read FIRST.
	var grad := Pasture3DGraphNodeGradient.new()
	var before := grad.input_unwired_default(1)
	grad.start = Vector2(before + 37.0, 5.0)
	_check(is_equal_approx(grad.input_unwired_default(1), before + 37.0), "Gradient start_x follows `start` (%s -> %s)" % [before, grad.input_unwired_default(1)])
	_check(is_equal_approx(grad.input_unwired_default(2), 5.0), "Gradient start_z follows `start`")

	var t0 := grad.output_port_type()
	grad.output_mode = Pasture3DGraphNodeGradient.OutputMode.HEIGHT if t0 == PT.MASK else Pasture3DGraphNodeGradient.OutputMode.MASK
	_check(grad.output_port_type() != t0, "Gradient's output type follows Output Mode (%d -> %d)" % [t0, grad.output_port_type()])

	var meas := Pasture3DGraphNodeMeasure.new()
	var n0 := meas.output_names()[0]
	meas.mode = Pasture3DGraphNodeMeasure.Mode.MEAN
	_check(meas.output_names()[0] == "mean" and n0 != "mean", "Measure's output label follows its mode ('%s' -> '%s')" % [n0, meas.output_names()[0]])
	_check(meas.output_ports()[0].id == &"min", "and its id does not: still '%s', so a saved wire survives the mode change" % meas.output_ports()[0].id)

	var gav := Pasture3DGraphNodeGavoronoise.new()
	var s0 := gav.input_unwired_default(4)
	gav.fit_to_base = not gav.fit_to_base
	_check(gav.input_unwired_default(4) != s0, "Gavoronoise's min sentinel follows Fit To Base (%s -> %s)" % [s0, gav.input_unwired_default(4)])

	# A property-backed port is read live rather than cached, so it needs no `changed` at all.
	var con := Pasture3DGraphNodeContrast.new()
	con.input_unwired_default(1)
	con.amount = 2.75
	_check(is_equal_approx(con.input_unwired_default(1), 2.75), "Contrast amount reads its property (%s)" % con.input_unwired_default(1))

	# CONTROL. A node whose `_init` does not chain `super()` never bumps the revision the cache keys on, so
	# the same read-set-read goes stale — which is the failure the checks above are able to see.
	var stale := _NoSuperInit.new()
	stale.input_unwired_default(0)
	stale.level = 9.0
	_check(is_equal_approx(stale.input_unwired_default(0), 1.0), "control: a node that never signals a change keeps its first answer (%s)" % stale.input_unwired_default(0))


class _NoSuperInit extends Pasture3DGraphNode:
	var level: float = 1.0:
		set(v):
			level = v
			emit_changed()

	func _init() -> void:
		pass

	func _inputs() -> Array[Pasture3DGraphPort]:
		return [Pasture3DGraphPort.value(&"level", PortType.FLOAT).unwired(level)]


# ---- [B] -------------------------------------------------------------------------------------------

func _b_programs_equal_golden() -> void:
	print("\n[B] every registered node compiles to the program it compiled to before")
	var golden := _golden(Programs.GOLDEN)
	var now := Programs.table()
	var lowered := 0
	for r in now:
		if not r.ends_with("|none"):
			lowered += 1
	_check(lowered >= 150, "%d of %d fixtures lower to a program at all" % [lowered, now.size()])
	var d := _diff(now, golden)
	_check(d.is_empty(), "%d fingerprints, identical%s" % [now.size(), "" if d.is_empty() else " — " + "; ".join(d.slice(0, 8))])
	# CONTROL. The same node with ONE port's params slot moved lowers to a different program, wired. (The
	# spec's wording is "one port type changed"; a type alone does not reach the program, a slot does.)
	var real := Programs.fingerprint(Pasture3DGraphNodeContrast.new(), true)
	var moved := Programs.fingerprint(_ContrastSlotMoved.new(), true)
	_check(real != "none" and moved != "none", "control fixtures lower (%s, %s)" % [real, moved])
	_check(real != moved, "control: moving one port's params slot changes the fingerprint")


class _ContrastSlotMoved extends Pasture3DGraphNodeContrast:
	func _inputs() -> Array[Pasture3DGraphPort]:
		return [
			Pasture3DGraphPort.field(&"in", PortType.HEIGHT).require(),
			Pasture3DGraphPort.value(&"amount", PortType.FLOAT, &"amount", 2),
			Pasture3DGraphPort.field(&"mask", PortType.MASK).unwired(1.0).as_aux(),
		]


# ---- [C] -------------------------------------------------------------------------------------------

func _every_node() -> Array:
	var out: Array = []
	for path in Table.node_scripts():
		var s := load(path) as GDScript
		if s != null and s.can_instantiate():
			out.append([path.get_file().get_basename(), s.new()])
	return out


func _duplicate_ids(p_node: Pasture3DGraphNode) -> PackedStringArray:
	var out := PackedStringArray()
	for group in [p_node.input_ports(), p_node.output_ports()]:
		var seen := {}
		for p in group:
			if p.id == &"" or seen.has(p.id):
				out.append(String(p.id) if p.id != &"" else "<empty>")
			seen[p.id] = true
	return out


func _c_ids_are_unique() -> void:
	print("\n[C] port ids are unique within a node")
	var bad := PackedStringArray()
	var ports := 0
	for row in _every_node():
		var n: Pasture3DGraphNode = row[1]
		ports += n.input_ports().size() + n.output_ports().size()
		for id in _duplicate_ids(n):
			bad.append("%s.%s" % [row[0], id])
	_check(ports > 600, "%d ports examined" % ports)
	_check(bad.is_empty(), "no duplicate or empty id%s" % ["" if bad.is_empty() else " — " + ", ".join(bad)])
	_check(_duplicate_ids(_DupId.new()) == PackedStringArray(["in"]), "control: a node declaring 'in' twice is caught")


class _DupId extends Pasture3DGraphNode:
	func _inputs() -> Array[Pasture3DGraphPort]:
		return [Pasture3DGraphPort.field(&"in", PortType.HEIGHT), Pasture3DGraphPort.field(&"in", PortType.MASK)]


# ---- [D] -------------------------------------------------------------------------------------------

func _missing_properties(p_node: Pasture3DGraphNode) -> PackedStringArray:
	var have := {}
	for prop in p_node.get_property_list():
		have[StringName(prop.get("name", &""))] = true
	var out := PackedStringArray()
	for p in p_node.input_ports():
		if p.property != &"" and not have.has(p.property):
			out.append("%s -> %s" % [p.id, p.property])
	return out


func _d_properties_exist() -> void:
	print("\n[D] every property a port names exists on its node")
	var bad := PackedStringArray()
	var named := 0
	for row in _every_node():
		var n: Pasture3DGraphNode = row[1]
		for p in n.input_ports():
			if p.property != &"":
				named += 1
		for m in _missing_properties(n):
			bad.append("%s: %s" % [row[0], m])
	_check(named >= 120, "%d ports name a property" % named)
	_check(bad.is_empty(), "all of them exist%s" % ["" if bad.is_empty() else " — " + "; ".join(bad)])
	_check(_missing_properties(_MissingProp.new()).size() == 1, "control: a port naming a property the node lacks is caught")


class _MissingProp extends Pasture3DGraphNode:
	func _inputs() -> Array[Pasture3DGraphPort]:
		return [Pasture3DGraphPort.value(&"amount", PortType.FLOAT, &"amuont")]


# ---- [E] -------------------------------------------------------------------------------------------

class _PathOut extends Pasture3DGraphNode:
	func _inputs() -> Array[Pasture3DGraphPort]:
		return []

	func _outputs() -> Array[Pasture3DGraphPort]:
		return [Pasture3DGraphPort.field(&"path", PortType.PATH)]


func _e_connect_refuses() -> void:
	print("\n[E] connect_ports refuses what the matrix refuses")
	var g := Pasture3DTerrainGraph.create_empty()
	var path_i := g.add_node(_PathOut.new())
	var const_i := g.add_node(Pasture3DGraphNodeConst.new())
	var relay_i := g.add_node(Pasture3DGraphNodeReroute.new())
	var out_i := g.add_node(Pasture3DGraphNodeOutput.new())
	g.set_output(out_i)

	# CONTROL FIRST. A legal wire is accepted and stored, so "refused" below is not "nothing connects".
	_check(g.connect_ports(const_i, 0, relay_i, 0), "control: FLOAT -> HEIGHT is accepted")
	_check(g.connections.size() == 1, "control: and stored (%d wires)" % g.connections.size())
	_check(g.connect_ports(relay_i, 0, out_i, 0), "control: HEIGHT -> HEIGHT is accepted")

	var before: Array = g.connections.duplicate(true)
	_check(not g.connect_ports(path_i, 0, relay_i, 0), "PATH -> HEIGHT is refused")
	_check(g.connections == before, "and `connections` is unchanged — the wire it would have replaced is still there")
	_check(not g.connect_ports(const_i, 3, relay_i, 0) and not g.connect_ports(const_i, 0, relay_i, 7)
			and not g.connect_ports(99, 0, relay_i, 0) and g.connections == before,
			"a port or node index that does not exist is refused too")

	var clean := g.graph_warnings()
	var clean_hits := 0
	for line in clean:
		if line.contains("not valid"):
			clean_hits += 1
	_check(clean_hits == 0, "control: a graph of legal wires reports no invalid wire")
	# A wire stored before the check existed: written straight into `connections`.
	var stored: Array = g.connections.duplicate(true)
	stored[0] = PackedInt32Array([path_i, 0, relay_i, 0])
	g.connections = stored
	var hits := 0
	for line in g.graph_warnings():
		if line.contains("not valid") and line.contains("PATH") and line.contains("HEIGHT"):
			hits += 1
	_check(hits == 1, "a stored PATH -> HEIGHT wire is reported once, naming both types")
	_check(g.connections.size() == 2, "and is left in place rather than dropped")


# ---- [F] -------------------------------------------------------------------------------------------

func _unwired_lines(p_g: Pasture3DTerrainGraph) -> PackedStringArray:
	var out := PackedStringArray()
	for line in p_g.graph_warnings():
		if line.contains("is unconnected"):
			out.append(line)
	return out


func _f_only_required_ports_warn() -> void:
	print("\n[F] only a required port warns when unwired")
	var g := Pasture3DTerrainGraph.create_empty()
	var const_i := g.add_node(Pasture3DGraphNodeConst.new())
	var con := Pasture3DGraphNodeContrast.new()
	var con_i := g.add_node(con)
	var out_i := g.add_node(Pasture3DGraphNodeOutput.new())
	g.set_output(out_i)
	g.connect_ports(const_i, 0, con_i, 0)
	g.connect_ports(con_i, 0, out_i, 0)
	var ports := con.input_ports()
	_check(ports[0].required and not ports[1].required and not ports[2].required,
			"Contrast declares `in` required and `amount`, `mask` optional")
	# `amount` and `mask` are unwired here. Both used to warn "reads 0", and `mask` reads 1.
	var lines := _unwired_lines(g)
	_check(lines.is_empty(), "with only optional ports unwired there is no unwired warning%s" % ["" if lines.is_empty() else " — " + "; ".join(lines)])

	# CONTROL. Unwire the required port and the warning appears, for that port and no other.
	g.disconnect_ports(const_i, 0, con_i, 0)
	lines = _unwired_lines(g)
	_check(lines.size() == 1 and lines[0].contains("'in'"), "control: unwiring `in` warns once, for `in`%s" % ["" if lines.size() == 1 else " — got %d" % lines.size()])
	_check(lines.size() == 1 and lines[0].contains("reads 0"), "and says what it reads")

	# The number in the message is the port's own default, not a hardcoded 0.
	var g2 := Pasture3DTerrainGraph.create_empty()
	var req_i := g2.add_node(_RequiredAtSeven.new())
	g2.set_output(req_i)
	lines = _unwired_lines(g2)
	_check(lines.size() == 1 and lines[0].contains("reads 7"), "a required port that reads 7 unwired is reported as reading 7%s" % ["" if lines.is_empty() else " — " + lines[0]])


class _RequiredAtSeven extends Pasture3DGraphNode:
	func _inputs() -> Array[Pasture3DGraphPort]:
		return [Pasture3DGraphPort.field(&"in", PortType.HEIGHT).unwired(7.0).require()]


# ---- [G] -------------------------------------------------------------------------------------------

func _g_editor_matrix_is_can_connect() -> void:
	print("\n[G] the editor registers exactly the matrix the model enforces")
	var ge := GraphEdit.new()
	add_child(ge)
	Pasture3DGraphEditor.register_connection_types(ge)
	var wrong := PackedStringArray()
	var cross := 0
	var allowed := 0
	for from_t in PT.values():
		for to_t in PT.values():
			cross += 1
			var model: bool = Pasture3DGraphNode.can_connect(from_t, to_t)
			if model:
				allowed += 1
			if ge.is_valid_connection_type(from_t, to_t) != model:
				wrong.append("%d->%d" % [from_t, to_t])
	_check(allowed == 39, "%d of %d ordered pairs are legal (7 scalar types crossed less the 12 field -> value pairs, plus COLOR and PATH to themselves; the three retired types connect to nothing)" % [allowed, cross])
	_check(wrong.is_empty(), "the editor agrees on every pair%s" % ["" if wrong.is_empty() else " — " + ", ".join(wrong)])
	_check(Pasture3DGraphNode.can_connect(PT.COLOR, PT.COLOR) and not Pasture3DGraphNode.can_connect(PT.COLOR, PT.FLOAT)
			and not Pasture3DGraphNode.can_connect(PT.HEIGHT, PT.PATH), "COLOR and PATH connect only to themselves")
	# CONTROL. A GraphEdit with one extra pair registered disagrees on exactly that pair.
	ge.add_valid_connection_type(PT.PATH, PT.HEIGHT)
	_check(ge.is_valid_connection_type(PT.PATH, PT.HEIGHT) != Pasture3DGraphNode.can_connect(PT.PATH, PT.HEIGHT),
			"control: an editor that also allowed PATH -> HEIGHT would be caught")
	ge.queue_free()
