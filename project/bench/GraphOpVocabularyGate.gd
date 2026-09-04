# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphOpVocabularyGate — every op declares its native wiring in ONE place, and that place is the node.
# PASTURE3D_PIPELINE_REMEDIATION_SPEC.md P6 §6.1.
#
# The op vocabulary used to live in FIVE host-side tables in `pasture3d_terrain_graph.gd`, all keyed by op
# string and all describing nodes from the outside: `_lower_node_op` (70 literal `op_id = <int>` plus 60
# match arms marshalling parameters), the cell-path match (the same ids restated), `PARAM_PORT_MAP`,
# `SUPPORTED` and `NATIVE_OUT_COUNT`.
#
# Four shipped bugs of that exact shape are on the record — Crater baking a fixed amplitude of 25.0, Warp
# putting `strength` in the slot the kernel reads as the noise TYPE, Curve naming five properties that do
# not exist (and throwing on `bool(null)`), Mask reading `mode` for `property` so every mask lowered as
# SLOPE. All four were a table naming a property the node does not have, and all four were SILENT:
# `node.get("typo")` returns null and the arm fell through to a hardcoded default, so the graph produced a
# plausible surface instead of an error.
#
#   [A] every registered op's native id comes from the C++ list and from nowhere else
#   [B] a node's `native_lower()` reads its own real properties — the whole bug class above
#   [C] the five host-side tables are gone, not merely bypassed
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project res://bench/GraphOpVocabularyGate.tscn
extends Node

## Below this many ops actually exercised, [B] is measuring its own skip conditions and not the registry.
const MIN_LOWERABLE := 40

var _fail := 0


func _ready() -> void:
	print("=== GraphOpVocabularyGate: the op vocabulary lives on the node (P6 §6.1) ===\n")
	_a_ids_come_from_cpp()
	_b_lowerings_read_real_properties()
	_c_the_host_tables_are_gone()
	print("\n=== %s (%d failures) ===\n" % ["GRAPH OP VOCABULARY PASS" if _fail == 0 else "GRAPH OP VOCABULARY FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])


# --- A. the id is written once, in C++ ---------------------------------------------------------------
func _a_ids_come_from_cpp() -> void:
	print("[A] every lowered op's id comes from Pasture3DUtil.graph_op_ids()")
	var ids := Pasture3DTerrainGraph.op_ids()
	_check(not ids.is_empty(), "the C++ list is reachable at all (%d ops)" % ids.size())
	if ids.is_empty():
		return

	var g := Pasture3DTerrainGraph.new()
	var lowered := 0
	var wrong: Array[String] = []
	for entry in Pasture3DGraphNodeRegistry.entries(true):
		var op: StringName = entry.get("op", &"")
		var n: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op) if op != &"" else null
		if n == null:
			continue
		var low: Dictionary = g._lower_node_op(n)
		if ids.has(op):
			lowered += 1
			if low.is_empty() or int(low.get("op", -1)) != int(ids[op]):
				wrong.append("%s lowered as %s, C++ says %d" % [op, low.get("op", "{}"), int(ids[op])])
		elif not low.is_empty():
			# An op with no entry in the C++ list must NOT lower. This is the half that used to be silent:
			# `SUPPORTED` and the id literals were two lists that had to agree, and when they did not the
			# failure was a whole graph quietly dropping to the script evaluator.
			wrong.append("%s has no id in C++ but still lowered as %s" % [op, low.get("op")])
	_check(wrong.is_empty(), "%d ops lower to the id C++ names%s" % [lowered, "" if wrong.is_empty() else " — " + "; ".join(wrong)])

	# CONTROL. An op absent from the C++ list must lower to {}, so [A] is not passing merely because
	# everything lowers to something.
	var unknown := _DeafCrater.new()
	unknown.set_meta(&"tag", &"pasture3d_no_such_op")
	_check(g._lower_node_op(unknown).is_empty(), "control: an op absent from the C++ list refuses to lower")


# --- B. a lowering reads the node's own properties ----------------------------------------------------
func _b_lowerings_read_real_properties() -> void:
	print("\n[B] native_lower() reads properties the node actually has")
	var checked := 0
	var deaf: Array[String] = []
	for entry in Pasture3DGraphNodeRegistry.entries(true):
		var op: StringName = entry.get("op", &"")
		var probe: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op) if op != &"" else null
		if probe == null:
			continue
		# Params AND the curve LUT. Const Curve's five params are fixed constants on purpose — an identity
		# remap, because its whole content is the LUT — so judging params alone would report the one node
		# whose marshalling the Curve bug was actually about as permanently deaf.
		var base := _lowered_signature(probe)
		if base.is_empty():
			continue # a structural op with nothing of its own to be deaf to
		# Mutate EVERY numeric parameter at once and require the marshalled block to move. A lowering that
		# named nothing real would keep its hardcoded defaults and produce the same 16 floats — exactly
		# what Crater, Warp, Curve and Mask each did before this moved onto the node.
		var moved: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(op)
		if _fingerprint(moved) == 0:
			continue # nothing about this node can be moved; it has no parameters to be deaf to
		checked += 1
		if _lowered_signature(moved) == base:
			deaf.append(String(op))
	_check(deaf.is_empty(), "%d parameterised ops respond to their own properties%s" % [checked, "" if deaf.is_empty() else " — deaf: " + ", ".join(deaf)])
	_check(checked >= MIN_LOWERABLE, "the sweep reached %d ops (floor %d)" % [checked, MIN_LOWERABLE])

	# CONTROL. The probe must be able to SEE a deaf lowering, or [B] passing means nothing.
	var deaf_node := _DeafCrater.new()
	var before := _lowered_signature(deaf_node)
	var deaf_moved := _fingerprint(deaf_node)
	_check(deaf_moved > 0, "control: the probe did move the deaf node's %d properties" % deaf_moved)
	_check(_lowered_signature(deaf_node) == before,
			"control: a lowering that ignores its properties is detectably deaf")


## A node that lowers a hardcoded block, the way all four recorded bugs did. Its only job is to prove
## [B]'s probe can fail — and, with its `tag` meta, that [A]'s can.
class _DeafCrater extends Pasture3DGraphNode:
	@export var amplitude: float = 20.0
	@export var floor_depth: float = 0.7

	func op() -> StringName:
		return get_meta(&"tag", &"crater")

	func native_lower() -> Dictionary:
		var p := PackedFloat32Array()
		p.resize(16)
		p[0] = 25.0 # the fixed amplitude the old table really did bake in
		return {"params": p}


## Everything a lowering marshals that a parameter can reach: the 16 scalars and the curve LUT. Empty
## when the node marshals nothing at all, which is right for the structural ops.
func _lowered_signature(p_n: Pasture3DGraphNode) -> Array:
	var low := p_n.native_lower()
	var params: PackedFloat32Array = low.get("params", PackedFloat32Array())
	var lut: PackedFloat32Array = low.get("lut", PackedFloat32Array())
	var any := not lut.is_empty()
	for v in params:
		any = any or v != 0.0
	return [] if not any else [params, lut]


## Move every parameter this node will actually accept, and report how many really changed.
##
## "Actually accept" matters: a property clamped by its setter, or ranged 0..1, silently swallows an
## out-of-range probe and hands back its default — Road Grade's `amount` does exactly that. A probe that
## did not check what it wrote would then report the node as deaf, which is a false alarm about the one
## bug class this gate exists for. So each candidate is written, read back, and only counted when it
## stuck. Values are derived from the property name, so they are stable across runs and independent of
## declaration order, and are kept off 0 and 1 where a lowering may write those literally.
func _fingerprint(p_n: Object) -> int:
	var moved := 0
	for prop in p_n.get_property_list():
		var nm: String = String(prop.get("name", ""))
		var usage: int = int(prop.get("usage", 0))
		if nm == "" or nm.begins_with("_") or (usage & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var was: Variant = p_n.get(nm)
		for cand in _candidates(prop, was):
			p_n.set(nm, cand)
			if not is_same(p_n.get(nm), was):
				moved += 1
				break
		p_n.set(nm, p_n.get(nm)) # leave whatever stuck; nothing here is restored
	return moved


## Values to try for one property, most-preferred first, honouring a PROPERTY_HINT_RANGE so a ranged or
## clamped parameter gets a value it can hold.
func _candidates(p_prop: Dictionary, p_was: Variant) -> Array:
	var nm: String = String(p_prop.get("name", ""))
	var t: int = int(p_prop.get("type", TYPE_NIL))
	var frac := float(absi(nm.hash()) % 977) / 977.0 * 0.6 + 0.2 # 0.2 .. 0.8 of the range
	var lo := NAN
	var hi := NAN
	if int(p_prop.get("hint", 0)) == PROPERTY_HINT_RANGE:
		var bits: PackedStringArray = String(p_prop.get("hint_string", "")).split(",")
		if bits.size() >= 2 and bits[0].is_valid_float() and bits[1].is_valid_float():
			lo = bits[0].to_float()
			hi = bits[1].to_float()
	match t:
		TYPE_FLOAT:
			if is_finite(lo) and is_finite(hi) and hi > lo:
				return [lo + (hi - lo) * frac, hi, lo]
			return [float(absi(nm.hash()) % 9973) * 0.001 + 2.5, 3.5]
		TYPE_INT:
			if is_finite(lo) and is_finite(hi) and hi > lo:
				return [int(lo + (hi - lo) * frac), int(hi), int(lo)]
			return [(absi(nm.hash()) % 7) + 2, 1]
		TYPE_BOOL:
			return [not bool(p_was)]
		TYPE_VECTOR2:
			var h := float(absi(nm.hash()) % 9973) * 0.001 + 2.5
			return [Vector2(h, h + 1.25)]
		TYPE_COLOR:
			return [Color(0.37, 0.61, 0.23, 1.0), Color(0.11, 0.83, 0.47, 1.0)]
		TYPE_OBJECT:
			# A Curve is a parameter too — the node bakes it into the 256-entry LUT, and the recorded Curve
			# bug was precisely about that marshalling. A fresh curve with a distinct shape is the probe.
			if p_was is Curve:
				var c := Curve.new()
				c.add_point(Vector2(0.0, 0.23))
				c.add_point(Vector2(0.5, 0.81))
				c.add_point(Vector2(1.0, 0.44))
				return [c]
	return []


# --- C. the tables are gone ---------------------------------------------------------------------------
func _c_the_host_tables_are_gone() -> void:
	print("\n[C] the five host-side op tables are deleted, not bypassed")
	var src := FileAccess.get_file_as_string("res://addons/pasture_3d/graph/pasture3d_terrain_graph.gd")
	_check(src.length() > 1000, "the host source is readable (%d chars)" % src.length())
	for nm in ["PARAM_PORT_MAP", "NATIVE_OUT_COUNT", "SUPPORTED"]:
		# Only a DECLARATION counts. The doc comments explaining what these used to be are the record of
		# why the move happened, and must survive.
		_check(not src.contains("const %s" % nm), "`%s` no longer declares a table" % nm)
	var re := RegEx.create_from_string("^\\s*op_id = [0-9]+")
	var literals := 0
	for line in src.split("\n"):
		if re.search(line) != null:
			literals += 1
	_check(literals == 0, "no hand-typed op id survives in the host (found %d)" % literals)

	# CONTROL: the scan can find what it is looking for.
	_check(re.search("\t\t\t\top_id = 18; p0 = 1.0") != null,
			"control: the id scan matches a line that does carry a literal")
