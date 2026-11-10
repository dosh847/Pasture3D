# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphPortIdGate — a saved wire names its ports by ID, so a port list can change without moving a wire.
# PASTURE3D_GRAPH_PORTS_AND_STRUCTURE_SPEC.md §7 (P3, format 2).
#
#   [A] a save and a reload preserves every wire of every demo graph, and a wire whose id its node no
#       longer declares is dropped and reported, never rebound;
#   [B] every demo graph, stored by id, resolves to the wires and compiles to the programs it had when it
#       was stored by index;
#   [C] declaring a port in FRONT of a node's others leaves a saved graph's wires on the ports they named;
#   [D] a format-1 file (index rows, no version) is refused and raises no script error;
#   [E] Transform, with its dead `offset` input removed, still resamples exactly as the kernel does, on
#       both routes, unwired and with a later port driven;
#   [F] no registered node declares a VECTOR, CURVE or TERRAIN_BUS port, and none of those connects;
#   [G] Mountain Range Radial's `angle` output, retyped VECTOR -> FIELD, can be wired and read.
#
# THE DEMO GRAPHS. The 39 fixtures in `bench/fixtures/graph_port_id/` are the terrain graphs of the seven
# demo scenes, lifted out as they stood after the conversion, each with the sub-resources it needs. A gate
# does not load a demo scene. `bench/golden/graph_port_id_records.json` is what `GraphPortIdRecord` read
# from the same 39 graphs BEFORE the conversion, when their wires were index rows. They are snapshots: a
# demo graph edited later is not re-checked here.
#
# RE-RECORDED 2026-11-10 for format 3 (ports spec P5), from the converted fixtures. P5 moved ports and
# changed what twelve nodes lower to, so the P3 record could not stay. Before it was replaced, every
# difference was traced: programs moved only at or downstream of a node P5 changed, index rows only
# into Displace (its mask went last), and the one id change is Leveler `mask` -> `area`. The first run
# of this comparison is what caught the converter missing that Leveler wire.
#
# Every criterion carries a control that must fail, on the same code path, except [B] and [E], which
# compare against something recorded or computed outside the code under test.
#
# `_ran` counts sub-cases that reached their assert. A GDScript error aborts the function it is in without
# failing anything, so a criterion that threw would otherwise read as a pass.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/GraphPortIdGate.tscn
extends Node

const Record := preload("res://bench/GraphPortIdRecord.gd")
const ShiftyScript := preload("res://bench/fixtures/graph_port_id_shifty_node.gd")
const GraphEditorScript := preload("res://addons/pasture_3d/src/graph_editor.gd")
const PT := Pasture3DGraphNode.PortType

const FIXTURES := "res://bench/fixtures/graph_port_id"
const FORMAT1 := "res://bench/fixtures/graph_port_id_format1/demo_pasture__Resource_tb013.tres"
const GOLDEN := "res://bench/golden/graph_port_id_records.json"
const TMP := "user://graph_port_id_gate"
const N_FIXTURES := 39
const N_WIRES := 226
const GW := 48
const GH := 48
const RECT := Rect2(0.0, 0.0, 96.0, 96.0)
const EPS := 1.0e-4
const EXPECTED_RAN := 47 # [A] 4 + 6, [B] 4, [C] 6, [D] 7, [E] 9, [F] 7, [G] 4

var _fail := 0
var _ran := 0


func _ready() -> void:
	print("\n=== GraphPortIdGate: wires are stored by port id (ports spec P3, format 2) ===\n")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP))
	_a_round_trip()
	_a_renamed_id_is_dropped()
	_b_fixtures_equal_golden()
	_c_inserted_port_moves_no_wire()
	_d_format_1_is_refused()
	_e_transform_without_offset()
	_f_no_retired_ports()
	_g_radial_angle_is_a_field()
	print("\n    sub-cases that reached their assert: %d (want %d)" % [_ran, EXPECTED_RAN])
	if _ran != EXPECTED_RAN:
		_fail += 1; print("    !! a criterion stopped early — a script error aborted it, or the count is stale")
	print("\n=== %s (%d failures) ===\n" % ["GRAPH PORT ID PASS" if _fail == 0 else "GRAPH PORT ID FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_ok: bool, p_what: String) -> void:
	_ran += 1
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_what])


func _fixture_names() -> Array:
	var names: Array = []
	for fn in DirAccess.get_files_at(FIXTURES):
		if String(fn).ends_with(".tres"):
			names.append(String(fn))
	names.sort()
	return names


func _load(p_path: String) -> Pasture3DTerrainGraph:
	return ResourceLoader.load(p_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Pasture3DTerrainGraph


func _rows(p_graph: Pasture3DTerrainGraph) -> Array:
	var out: Array = []
	for c in p_graph.connections:
		out.append([int(c[0]), int(c[1]), int(c[2]), int(c[3])])
	return out


## Through JSON and back, so a record made here compares equal to one read from the golden file (which
## has every number as a float and every id as a String).
func _norm(p_v):
	return JSON.parse_string(JSON.stringify(p_v, "", true))


# ---- [A] -------------------------------------------------------------------------------------------

func _a_round_trip() -> void:
	print("[A] a save and a reload preserves every wire of every demo graph")
	var names := _fixture_names()
	var graphs := 0
	var wires := 0
	var lost: Array[String] = []
	var index_rows_on_disk := 0
	for fn in names:
		var g := _load(FIXTURES.path_join(fn))
		if g == null:
			lost.append("%s did not load" % fn)
			continue
		var before := _rows(g)
		var path := TMP.path_join("rt_" + fn)
		if ResourceSaver.save(g, path) != OK:
			lost.append("%s did not save" % fn)
			continue
		var text := FileAccess.get_file_as_string(path)
		if text.contains("\nconnections = "):
			index_rows_on_disk += 1
		var back := _load(path)
		if back == null or _rows(back) != before or back.format_version != Pasture3DTerrainGraph.FORMAT_CURRENT:
			lost.append("%s reloaded with different wires" % fn)
		graphs += 1
		wires += before.size()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	for l in lost:
		print("        " + l)
	_check(names.size() == N_FIXTURES, "%d fixtures found (want %d)" % [names.size(), N_FIXTURES])
	_check(lost.is_empty() and graphs == N_FIXTURES, "%d graphs saved and reloaded with the same wires" % graphs)
	_check(wires == N_WIRES, "%d wires went through the round trip (want %d, or the fixtures are not the demo graphs)"
			% [wires, N_WIRES])
	_check(index_rows_on_disk == 0, "%d saved file(s) still hold a `connections` line (want 0: it is not stored)"
			% index_rows_on_disk)


func _a_renamed_id_is_dropped() -> void:
	print("[A] control: a wire whose id is renamed in the file is dropped and reported, and the rest stay")
	var g := Pasture3DTerrainGraph.create_empty()
	var a := g.add_node(Pasture3DGraphNodeRegistry.create(&"input"))
	var b := g.add_node(Pasture3DGraphNodeRegistry.create(&"smooth"))
	var c := g.add_node(Pasture3DGraphNodeRegistry.create(&"output"))
	g.connect_ports(a, 0, b, 0)
	g.connect_ports(b, 0, c, 0)
	g.set_output(c)
	var path := TMP.path_join("renamed.tres")
	ResourceSaver.save(g, path)
	var text := FileAccess.get_file_as_string(path)
	var intact := _load(path)
	_check(intact != null and _rows(intact) == [[a, 0, b, 0], [b, 0, c, 0]] and not _mentions(intact.graph_warnings(), "dropped"),
			"untouched, the file reloads with both wires and no dropped-wire warning")

	# Rename the TO id of the first stored row. Nothing else in the file changes.
	var re := RegEx.new()
	re.compile("(wires = \\[\\[\\d+, &\"[^\"]+\", \\d+, &\")([^\"]+)(\")")
	var m := re.search(text)
	_check(m != null, "the saved file holds a `wires` line of [node, id, node, id] rows")
	if m == null:
		return
	var edited := text.substr(0, m.get_start(2)) + "gone_port" + text.substr(m.get_end(2))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(edited)
	f.close()
	var back := _load(path)
	var warn := back.graph_warnings() if back != null else PackedStringArray()
	var dropped := 0
	for line in warn:
		if line.contains("A saved wire was dropped") and line.contains("gone_port"):
			dropped += 1
	print("        was '%s'; reloaded wires %s" % [m.get_string(2), _rows(back) if back != null else []])
	_check(back != null and _rows(back) == [[b, 0, c, 0]], "exactly the renamed wire is gone and the other is where it was")
	_check(dropped == 1, "graph_warnings names the dropped wire by its id, once (found %d)" % dropped)
	# Never rebound: nothing is wired into the port that sits where the renamed one did.
	var into_b := 0
	for row in (_rows(back) if back != null else []):
		if row[2] == b:
			into_b += 1
	_check(into_b == 0, "the renamed wire was not rebound to another port of the same node")
	# The file's next save no longer carries it. Said out loud because it is a loss, and a deliberate one.
	ResourceSaver.save(back, path)
	_check(not FileAccess.get_file_as_string(path).contains("gone_port"), "the next save does not write the dropped wire back")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _mentions(p_w: PackedStringArray, p_needle: String) -> bool:
	for line in p_w:
		if line.contains(p_needle):
			return true
	return false


# ---- [B] -------------------------------------------------------------------------------------------

func _b_fixtures_equal_golden() -> void:
	print("[B] every demo graph resolves and compiles as it did when it was stored by index")
	var golden = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN))
	_check(golden is Dictionary and (golden as Dictionary).size() == N_FIXTURES,
			"the pre-conversion record holds %d graphs (want %d)" % [(golden as Dictionary).size() if golden is Dictionary else 0, N_FIXTURES])
	if not (golden is Dictionary):
		return
	var diffs: Array[String] = []
	var missing: Array[String] = []
	var compared := 0
	var lowered := 0
	for fn in _fixture_names():
		if not golden.has(fn):
			missing.append(fn)
			continue
		var rec: Dictionary = _norm(Record.record(_load(FIXTURES.path_join(fn))))
		var want: Dictionary = golden[fn]
		for key in ["ops", "rows", "ids", "problems", "programs", "output_node"]:
			if JSON.stringify(rec.get(key), "", true) != JSON.stringify(want.get(key), "", true):
				diffs.append("%s: %s differs" % [fn, key])
		for p in want.get("programs", []):
			if p != "none":
				lowered += 1
		compared += 1
	for d in diffs:
		print("        " + d)
	_check(missing.is_empty(), "every fixture has a pre-conversion record (%d missing)" % missing.size())
	_check(diffs.is_empty() and compared == N_FIXTURES, "%d graphs compared, %d differing field(s)" % [compared, diffs.size()])
	_check(lowered >= 200, "%d of the recorded programs are real ones (a record of 'none' compares equal to anything broken)" % lowered)


# ---- [C] -------------------------------------------------------------------------------------------

func _c_inserted_port_moves_no_wire() -> void:
	print("[C] a port declared in front of the others leaves a saved graph's wires on the ports they named")
	var g := Pasture3DTerrainGraph.create_empty()
	var ca := Pasture3DGraphNodeRegistry.create(&"const")
	var cb := Pasture3DGraphNodeRegistry.create(&"const")
	var shifty: Pasture3DGraphNode = ShiftyScript.new()
	g.add_node(ca); g.add_node(cb); g.add_node(shifty)
	_check(g.connect_ports(0, 0, 2, 0) and g.connect_ports(1, 0, 2, 1), "the fixture wires Const -> a and Const -> b")
	var old_rows := _rows(g)
	var path := TMP.path_join("shifty.tres")
	ResourceSaver.save(g, path)
	var text := FileAccess.get_file_as_string(path)

	# The edit, made where a plugin update makes it: the node's script now declares one more port, first.
	# Here that is a property in the file, so the same script serves both sides.
	var re := RegEx.new()
	re.compile("\\[ext_resource [^\\]]*graph_port_id_shifty_node\\.gd\"[^\\]]*id=\"([^\"]+)\"\\]")
	var m := re.search(text)
	_check(m != null, "the saved file references the fixture node's script")
	if m == null:
		return
	var script_line := "script = ExtResource(\"%s\")" % m.get_string(1)
	var edited := text.replace(script_line, script_line + "\nextra_first = true")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(edited)
	f.close()
	var back := _load(path)
	var node: Pasture3DGraphNode = back.nodes[2] if back != null and back.nodes.size() == 3 else null
	# The standard mask (P5) is appended after the declared ports, so it is not one of the three.
	_check(node != null and node.input_count() - (1 if node.standard_mask_port() >= 0 else 0) == 3
			and node.input_ports()[0].id == &"extra",
			"reloaded, the node declares three inputs with the new one first")
	if node == null:
		return
	var to_ids: Array = []
	for row in _rows(back):
		to_ids.append(String(node.input_ports()[row[3]].id))
	print("        index rows before %s, after %s; the wires land on %s" % [old_rows, _rows(back), to_ids])
	_check(_rows(back) == [[0, 0, 2, 1], [1, 0, 2, 2]] and to_ids == ["a", "b"],
			"both wires are still on `a` and `b`, one index further along")

	# CONTROL: the same edit under index storage. The rows the old file held, read against the new port
	# list, are on `extra` and `a` — every wire one port too early, which is the bug this phase removes.
	back.connections = [PackedInt32Array(old_rows[0]), PackedInt32Array(old_rows[1])]
	var moved: Array = []
	for w in back.wires:
		moved.append(String(w[3]))
	_check(moved == ["extra", "a"], "control: the old index rows on the new node name %s (want [extra, a], i.e. moved)" % [moved])
	_check(moved != to_ids, "control: index storage and id storage disagree about this file, so [C] can fail")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# ---- [D] -------------------------------------------------------------------------------------------

func _d_format_1_is_refused() -> void:
	print("[D] a format-1 file is refused and raises no script error")
	var text := FileAccess.get_file_as_string(FORMAT1)
	_check(text.contains("\nconnections = ") and not text.contains("format_version") and not text.contains("\nwires = "),
			"the fixture is a format-1 file: index rows, no version, no `wires`")
	var old := _load(FORMAT1)
	_check(old != null and old.format_version < Pasture3DTerrainGraph.FORMAT_MIN_COMPATIBLE and not old.is_compatible(),
			"it loads, reads as format %d and is not compatible" % (old.format_version if old != null else -99))
	if old == null:
		return
	# What the loader did with the `connections` line. It is a plain script variable now, and Godot still
	# assigns it by name. Reported, not required either way: nothing may read it on a refused graph.
	print("        the loader left %d index row(s) in `connections` and %d row(s) in `wires`"
			% [old.connections.size(), old.wires.size()])
	var warn := old.graph_warnings(true)
	_check(warn.size() == 1 and warn[0] == old.format_refusal() and warn[0].contains("format 0"),
			"it warns with exactly the refusal line: %s" % (warn[0] if warn.size() > 0 else "<none>"))
	var surf := _bumps()
	_check(old.output_index() == -1 and old.compile_graph_program().is_empty() and old.compile_graph_program(3).is_empty()
			and not old.native_supported(), "it has no output, compiles nothing and is not native-supported")
	_check(_all_zero(old.evaluate(GW, GH, RECT, null, surf)), "it evaluates flat")

	# CONTROL: the same graph after the conversion. Same nodes, same wires, and it runs.
	var conv := _load(FIXTURES.path_join(FORMAT1.get_file()))
	_check(conv != null and conv.is_compatible() and conv.output_index() == 3 and not conv.compile_graph_program().is_empty(),
			"control: the converted file is compatible, has its output and compiles")
	_check(conv != null and _rows(conv).size() == 3 and conv.graph_warnings(true).size() < 1 + conv.nodes.size() * 4
			and not _mentions(conv.graph_warnings(true), "format"),
			"control: the converted file holds its three wires and no format warning")


# ---- [E] -------------------------------------------------------------------------------------------

func _e_transform_without_offset() -> void:
	print("[E] Transform resamples as the kernel does with its `offset` input gone")
	var t := Pasture3DGraphNodeTransform.new()
	t.offset = Vector2(23.0, -41.0)
	t.rotation_deg = 31.0
	t.scale = 0.8
	t.pivot = Vector2(10.0, 10.0)
	_check(t.input_count() == 5 and t.standard_mask_port() == 4 and t.input_index_of(&"offset") == -1 and t.input_index_of(&"rotation") == 1
			and t.input_index_of(&"scale") == 2 and t.input_index_of(&"amount") == 3,
			"Transform declares in, rotation, scale, amount, the standard mask — and no `offset`")
	var surf := _bumps()
	# The reference is the kernel called directly, with the node's properties and no graph: nothing in it
	# knows what a port is.
	var want: PackedFloat32Array = Pasture3DUtil.transform_grid(surf, GW, GH, RECT, t.offset, 31.0, 0.8, t.pivot, int(t.edge_mode), 1.0)
	var want55: PackedFloat32Array = Pasture3DUtil.transform_grid(surf, GW, GH, RECT, t.offset, 55.0, 0.8, t.pivot, int(t.edge_mode), 1.0)
	_check(_max_abs_diff(want, surf) > 0.05 and _max_abs_diff(want, want55) > 0.05,
			"control: the reference moves the field (%.3f), and 31° and 55° differ (%.3f)"
			% [_max_abs_diff(want, surf), _max_abs_diff(want, want55)])

	var g := Pasture3DTerrainGraph.create_empty()
	g.add_node(Pasture3DGraphNodeInput.new()); g.add_node(t); g.add_node(Pasture3DGraphNodeOutput.new())
	_check(g.connect_ports(0, 0, 1, 0) and g.connect_ports(1, 0, 2, 0), "Input -> Transform -> Output wires")
	g.output_node = 2
	var native := g.native_supported()
	var rn := g.evaluate(GW, GH, RECT, null, surf)
	g.force_gdscript_evaluation = true
	var rg := g.evaluate(GW, GH, RECT, null, surf)
	g.force_gdscript_evaluation = false
	print("        unwired: native route=%s, max |native - kernel| = %.9f, max |gdscript - kernel| = %.9f"
			% [native, _max_abs_diff(rn, want), _max_abs_diff(rg, want)])
	_check(native, "the graph takes the native route, so the first number below is not the GDScript route twice")
	_check(_max_abs_diff(rn, want) <= EPS, "unwired, the native route equals the kernel")
	_check(_max_abs_diff(rg, want) <= EPS, "unwired, the GDScript route equals the kernel")

	# A LATER port driven: `rotation` was input 2 and is input 1. A Const of 55 into it must rotate by 55
	# on both routes; if the slot map or `eval_grid` still counted the removed port, it would drive `scale`
	# (or nothing) instead.
	var c := Pasture3DGraphNodeRegistry.create(&"const")
	c.set("value", 55.0)
	var ci := g.add_node(c)
	_check(g.connect_ports(ci, 0, 1, t.input_index_of(&"rotation")), "Const 55 -> rotation wires")
	var wn := g.evaluate(GW, GH, RECT, null, surf)
	g.force_gdscript_evaluation = true
	var wg := g.evaluate(GW, GH, RECT, null, surf)
	g.force_gdscript_evaluation = false
	print("        rotation driven: max |native - kernel(55°)| = %.9f, max |gdscript - kernel(55°)| = %.9f"
			% [_max_abs_diff(wn, want55), _max_abs_diff(wg, want55)])
	_check(g.native_supported() and _max_abs_diff(wn, want55) <= EPS, "driven, the native route rotates by the wired 55°")
	_check(_max_abs_diff(wg, want55) <= EPS, "driven, the GDScript route rotates by the wired 55°")


# ---- [F] -------------------------------------------------------------------------------------------

class _VectorNode extends Pasture3DGraphNode:
	func _init() -> void:
		super()
	func op() -> StringName:
		return &"const"
	func _outputs() -> Array[Pasture3DGraphPort]:
		return [Pasture3DGraphPort.value(&"out", Pasture3DGraphNode.PortType.VECTOR)]


## Every port of `p_nodes` (each `[name, node]`) that declares a retired type.
func _retired_ports(p_nodes: Array) -> Array[String]:
	var out: Array[String] = []
	for pair in p_nodes:
		var n: Pasture3DGraphNode = pair[1]
		for p in n.input_ports():
			if Pasture3DGraphNode.is_retired_type(p.type):
				out.append("%s input '%s' is %s" % [pair[0], p.id, Pasture3DGraphNode.port_type_name(p.type)])
		for p in n.output_ports():
			if Pasture3DGraphNode.is_retired_type(p.type):
				out.append("%s output '%s' is %s" % [pair[0], p.id, Pasture3DGraphNode.port_type_name(p.type)])
	return out


func _f_no_retired_ports() -> void:
	print("[F] no registered node declares a VECTOR, CURVE or TERRAIN_BUS port, and none of them connects")
	var nodes: Array = []
	for e in Pasture3DGraphNodeRegistry.entries(true):
		nodes.append([String(e["op"]), (e["script"] as GDScript).new()])
	var found := _retired_ports(nodes)
	for line in found:
		print("        " + line)
	_check(nodes.size() >= 140, "%d registered nodes swept, dev twins included" % nodes.size())
	_check(found.is_empty(), "%d port(s) declare a retired type" % found.size())
	_check(Pasture3DGraphNodeRegistry.create(&"const_vector") == null and Pasture3DGraphNodeRegistry.create(&"const_curve") == null,
			"Const Vector and Const Curve are not in the registry")
	# CONTROL: the same sweep, handed a node that does declare one.
	var caught := _retired_ports([["fixture", _VectorNode.new()]])
	_check(caught.size() == 1 and caught[0].contains("VECTOR"), "control: a fixture node declaring a VECTOR output is caught (%s)" % [caught])

	var connects: Array[String] = []
	var ge := GraphEdit.new()
	add_child(ge)
	GraphEditorScript.register_connection_types(ge)
	for r in [PT.VECTOR, PT.CURVE, PT.TERRAIN_BUS]:
		for t in PT.values():
			if Pasture3DGraphNode.can_connect(r, t) or Pasture3DGraphNode.can_connect(t, r) \
					or ge.is_valid_connection_type(r, t) or ge.is_valid_connection_type(t, r):
				connects.append("%s <-> %s" % [Pasture3DGraphNode.port_type_name(r), Pasture3DGraphNode.port_type_name(t)])
	_check(connects.is_empty(), "a retired type connects to nothing, itself included, in the model and in the editor (%s)" % [connects])
	_check(Pasture3DGraphNode.can_connect(PT.COLOR, PT.COLOR) and Pasture3DGraphNode.can_connect(PT.PATH, PT.PATH)
			and ge.is_valid_connection_type(PT.COLOR, PT.COLOR),
			"control: COLOR and PATH still connect to themselves, so 'nothing connects' is not the answer to every pair")
	# A graph holding such a node cannot be wired from it.
	var g := Pasture3DTerrainGraph.create_empty()
	g.add_node(_VectorNode.new()); g.add_node(Pasture3DGraphNodeOutput.new())
	_check(not g.connect_ports(0, 0, 1, 0) and g.connections.is_empty(), "a VECTOR output cannot be wired to anything")
	ge.queue_free()


# ---- [G] -------------------------------------------------------------------------------------------

func _g_radial_angle_is_a_field() -> void:
	print("[G] Mountain Range Radial's `angle` output is a FIELD that wires and reads the same on both routes")
	var r: Pasture3DGraphNode = Pasture3DGraphNodeRegistry.create(&"mountain_range_radial")
	var ai := r.output_index_of(&"angle")
	_check(ai == 1 and r.output_ports()[ai].type == PT.FIELD, "`angle` is output 1 and declares FIELD")
	var g := Pasture3DTerrainGraph.create_empty()
	g.add_node(r); g.add_node(Pasture3DGraphNodeOutput.new())
	_check(g.connect_ports(0, ai, 1, 0), "angle -> Output wires (it was a VECTOR nothing could take)")
	g.output_node = 1
	var a := g.evaluate(GW, GH, RECT)
	g.force_gdscript_evaluation = true
	var b := g.evaluate(GW, GH, RECT)
	g.force_gdscript_evaluation = false
	var lo := INF
	var hi := -INF
	for v in a:
		lo = minf(lo, v); hi = maxf(hi, v)
	print("        angle field spans %.4f .. %.4f; max |default route - gdscript| = %.9f" % [lo, hi, _max_abs_diff(a, b)])
	_check(hi - lo > 0.1, "the wire carries a field that varies (span %.4f), not a flat fill" % (hi - lo))
	# CONTROL for the line above: the height output of the same node is a different field.
	g.connect_ports(0, 0, 1, 0)
	var h := g.evaluate(GW, GH, RECT)
	_check(_max_abs_diff(a, b) <= EPS and _max_abs_diff(a, h) > 0.1,
			"both routes agree on it, and it is not the height output (differs by %.3f)" % _max_abs_diff(a, h))


# ---- helpers ---------------------------------------------------------------------------------------

func _bumps() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(GW * GH)
	for z in range(GH):
		for x in range(GW):
			out[z * GW + x] = 20.0 * sin(float(x) * 0.31) * cos(float(z) * 0.23) + 0.4 * float(x) - 0.2 * float(z)
	return out


func _all_zero(p_grid: PackedFloat32Array) -> bool:
	for v in p_grid:
		if v != 0.0:
			return false
	return true


func _max_abs_diff(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var d := 0.0
	for i in range(p_a.size()):
		d = maxf(d, absf(p_a[i] - p_b[i]))
	return d
