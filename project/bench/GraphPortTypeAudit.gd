# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphPortTypeAudit — an INVENTORY of every registered node's port declarations, and the mechanical
# consistency checks that can be made against them without knowing what any node means.
#
# ---- WHAT THIS IS, AND WHAT IT IS NOT ----
#
# This is a PROBE, not a gate. It asserts nothing about whether a port carries the RIGHT type — that is a
# judgement about what a node produces and it cannot be made from the declarations alone. What it can do is
# print the whole table in one place, and flag the inconsistencies that are decidable:
#
#   1. a types array SHORTER than its port count. The editor reads `types[r] if r < types.size() else 0`
#      (graph_editor.gd `_populate_node_slots_and_controls`), so a short array does not error — every port
#      past the end silently becomes HEIGHT and gets HEIGHT's colour.
#   2. `output_port_type()` and `output_port_types()[0]` disagreeing. Two declarations of one fact, and
#      only some nodes override both.
#   3. the SCALAR/FIELD split contradicting itself: `native_param_ports()[i] >= 0` says port i carries one
#      number into a params slot, and a field type (HEIGHT / MASK / FIELD / SIGNED / TERRAIN_BUS / PATH) on the same port
#      says it carries a grid. Both cannot be true.
#   4. a names array shorter than its port count — the editor labels the port "" or "out".
#   5. a type index outside PORT_COLORS, which per PASTURE3D_TERRAIN_GRAPH_GUIDE.md §9 silently reuses
#      another type's colour rather than failing.
#
# Everything else in the output is inventory for a human to read.
#
# See PASTURE3D_GRAPH_PORT_TYPES_GUIDE.md for the process this probe supports.
extends Node

const FIELD_TYPES: Array[int] = [
	Pasture3DGraphNode.PortType.HEIGHT,
	Pasture3DGraphNode.PortType.MASK,
	Pasture3DGraphNode.PortType.FIELD,
	Pasture3DGraphNode.PortType.SIGNED,
	Pasture3DGraphNode.PortType.TERRAIN_BUS,
	Pasture3DGraphNode.PortType.PATH,
]

const TYPE_NAMES: Array[String] = [
	"HEIGHT", "MASK", "VECTOR", "CURVE", "FLOAT", "INT", "COLOR", "BOOL", "TERRAIN_BUS", "PATH",
	"FIELD", "SIGNED",
]

# graph_editor.gd PORT_COLORS length. Restated here deliberately: the point of check 5 is to notice when
# the enum grows past the colour table, and reading the table would make the check agree with itself.
const PORT_COLOR_COUNT: int = 12

var _findings: Array[String] = []


func _ready() -> void:
	print("=== GraphPortTypeAudit: every registered node's port declarations ===")
	print("    probe, not a gate — see PASTURE3D_GRAPH_PORT_TYPES_GUIDE.md\n")

	var entries: Array[Dictionary] = Pasture3DGraphNodeRegistry.entries(true)
	print("registry entries: %d\n" % entries.size())

	print("op\tcategory\trole\tport\tdir\tname\ttype\tparam_slot")
	for e in entries:
		_audit(e)

	print("\n=== FINDINGS (%d) ===" % _findings.size())
	for f in _findings:
		print("  " + f)
	print("\n=== PORT TYPE AUDIT COMPLETE (%d findings) ===\n" % _findings.size())
	get_tree().quit(0)


func _flag(p_op: StringName, p_text: String) -> void:
	_findings.append("%s: %s" % [p_op, p_text])


func _tname(p_t: int) -> String:
	if p_t >= 0 and p_t < TYPE_NAMES.size():
		return TYPE_NAMES[p_t]
	return "??(%d)" % p_t


func _audit(p_entry: Dictionary) -> void:
	var op: StringName = p_entry["op"]
	var node: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op)
	if node == null:
		_flag(op, "registry entry does not instantiate")
		return

	var cat: String = p_entry.get("category", "?")
	var role: String = p_entry.get("role", "?")

	var n_in: int = node.input_count()
	var in_names: PackedStringArray = node.input_names()
	var in_types: PackedInt32Array = node.input_port_types()
	var pmap: PackedInt32Array = node.native_param_ports()

	var has_out: bool = node.has_output()
	var n_out: int = node.output_count() if has_out else 0
	var out_names: PackedStringArray = node.output_names()
	var out_types: PackedInt32Array = node.output_port_types()

	# ---- inventory ----
	for i in range(n_in):
		var t: int = int(in_types[i]) if i < in_types.size() else -1
		var slot: int = int(pmap[i]) if i < pmap.size() else -1
		var nm: String = in_names[i] if i < in_names.size() else ""
		print("%s\t%s\t%s\t%d\tin\t%s\t%s\t%d" % [op, cat, role, i, nm, _tname(t), slot])
	for i in range(n_out):
		var t2: int = int(out_types[i]) if i < out_types.size() else -1
		var nm2: String = out_names[i] if i < out_names.size() else ""
		print("%s\t%s\t%s\t%d\tout\t%s\t%s\t-" % [op, cat, role, i, nm2, _tname(t2)])

	# ---- 1. short types arrays ----
	if in_types.size() < n_in:
		_flag(op, "input_port_types() has %d entries for %d ports — ports %d.. silently render as HEIGHT"
				% [in_types.size(), n_in, in_types.size()])
	if has_out and out_types.size() < n_out:
		_flag(op, "output_port_types() has %d entries for %d ports — ports %d.. fall back"
				% [out_types.size(), n_out, out_types.size()])

	# ---- 2. the two output declarations disagreeing ----
	if has_out and out_types.size() > 0 and node.output_port_type() != int(out_types[0]):
		_flag(op, "output_port_type()=%s but output_port_types()[0]=%s"
				% [_tname(node.output_port_type()), _tname(int(out_types[0]))])

	# ---- 3. scalar/field contradiction ----
	for i in range(mini(n_in, mini(in_types.size(), pmap.size()))):
		var t3: int = int(in_types[i])
		var slot3: int = int(pmap[i])
		if slot3 >= 0 and FIELD_TYPES.has(t3):
			_flag(op, "port %d ('%s') is a params slot (%d) but declares field type %s"
					% [i, (in_names[i] if i < in_names.size() else ""), slot3, _tname(t3)])

	# ---- 4. short names arrays ----
	if in_names.size() < n_in:
		_flag(op, "input_names() has %d entries for %d ports" % [in_names.size(), n_in])
	if has_out and out_names.size() < n_out:
		_flag(op, "output_names() has %d entries for %d ports" % [out_names.size(), n_out])

	# ---- 5. a type with no colour ----
	for t4 in in_types:
		if int(t4) < 0 or int(t4) >= PORT_COLOR_COUNT:
			_flag(op, "input type %d has no PORT_COLORS entry — reuses another type's colour" % int(t4))
	for t5 in out_types:
		if int(t5) < 0 or int(t5) >= PORT_COLOR_COUNT:
			_flag(op, "output type %d has no PORT_COLORS entry — reuses another type's colour" % int(t5))
