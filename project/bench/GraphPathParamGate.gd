# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphPathParamGate — a PATH graph parameter: one graph, several brushes, each carving its own spline.
#
# Pasture3DGraphParam.Type.PATH. The host supplies a spline KEY, the empty key is the host brush's own first
# Pasture3DSpline child, and the host resolves it to a path and stamps the PATH (Pasture3DNodeGraph
# .stamp_params). The fixture is the case the feature is for: two brushes sharing ONE modifier (a duplicated
# brush shares its stack), each with its own spline child, the two lines far enough apart that a mask of one
# is zero over the other.
#
#   PA  each host evaluates ITS OWN spline: host 1's program equals the same graph with Spline Source holding
#       spline 1, host 2's equals spline 2, and the two differ. Native equals GDScript for both.
#       Control: a modifier stamped with no host resolves no spline, so its mask is empty.
#   PB  stamping emits nothing on the shared graph, so host 1's bake cannot re-bake host 2.
#       Control: the old way, a shared Spline Source with the empty key resolved for each host, emits.
#   PC  keys: the two hosts key differently; re-stamping an unchanged spline keeps the key and the SAME path
#       instance (downstream path caches key on the instance); moving a spline point moves its host's key.
#       Control: with the per-host memo dropped, an unchanged spline stamps a new instance.
#   PD  a typed key overrides the empty one: host 1 reads spline 2 by key. A key naming nothing, and an empty
#       key on a brush with no spline child, are both warned.
#       Control: a host whose key resolves raises no spline-parameter warning.
#   PE  a spline edit re-bakes the brushes reading it and no others: spline 1 is read by host 1 only, spline 2
#       by host 2 and by a third brush naming it by key.
#       Control: a brush whose graph has no PATH parameter reads neither.
#   PF  the host inspector shows the parameter as a String with the scene's spline keys offered, under its
#       own Parameters group, with a read-only readout naming the spline it resolves to; it reads the empty
#       key by default, and stores a typed key; setting it back to empty clears the override.
#   PG  `content_key` (the modifier signature's key) follows the host named at the last stamp, so the shared
#       modifier keys host 2's spline after host 2 stamps.
#       Control: host 1's key before is not host 2's key.
#   PH  pointing an UNWIRED Parameter node at a PATH declaration retypes its port AND emits
#       `structure_changed`, which is what makes the graph editor redraw its slot. Unwired, it feeds no
#       output and emits no `changed`, so without this the editor kept a Float slot that refused the wire.
#       Control: pointing it at another declaration of the SAME type emits nothing.
#   PI  a duplicated brush gets its own graph modifier on the SAME graph (Pasture3DBrushGraphRow
#       .unshare_graph_mods, which the brush runs on _ready in the editor), and a key naming the original's
#       own spline is dropped, so the duplicate reads ITS own spline.
#       Controls: the brush left holding the original keeps the original and its key; a key naming the
#       spline of a brush that does NOT host the graph survives the split.
#   PJ  picking the host's own spline in the dropdown stores the empty key ("my own spline"), so a later
#       duplicate reads its own and not the original's by name.
#       Control: picking another brush's spline stores that key.
#
# Every criterion reports through `_check`. CRITERIA lists them, and one that never reported fails the run.
#
# Run: Godot_v4.7-stable_win64_console.exe --headless --path project bench/GraphPathParamGate.tscn
extends Node

const CRITERIA: Array[String] = ["PA", "PB", "PC", "PD", "PE", "PF", "PG", "PH", "PI", "PJ"]
const N := 64
const RECT := Rect2(-100.0, -100.0, 400.0, 200.0)
const SITE_1 := Vector3(0.0, 0.0, 0.0)
const SITE_2 := Vector3(200.0, 0.0, 0.0)

var _fail := 0
var _reported := {}
var _emits := 0


func _ready() -> void:
	print("=== GraphPathParamGate: a PATH parameter, one spline per host ===\n")
	var t := Pasture3D.new()
	t.name = "Terrain"
	add_child(t)
	var b1 := _brush(t, "Hill1", SITE_1, true)
	var b2 := _brush(t, "Hill2", SITE_2, true)
	var b3 := _brush(t, "Bare", Vector3(0.0, 0.0, 120.0), false)
	var g := _graph()
	var mod := _host(g)
	b1.modifiers = [mod] as Array[Pasture3DNode]
	b2.modifiers = [mod] as Array[Pasture3DNode]
	var s1 := Pasture3DGraphSources.own_spline(b1)
	var s2 := Pasture3DGraphSources.own_spline(b2)
	if s1 == null or s2 == null:
		_fail += 1
		print("!!  fixture: a brush has no spline child")
	else:
		_pa(g, mod, b1, b2, s1, s2)
		_pb(g, mod, b1, b2)
		_pc(g, mod, b1, b2, s1)
		_pd(g, b1, b3, s2)
		_pe(t, b1, b2, s1, s2)
		_pf(mod, b1, s2)
		_pg(mod, b1, b2)
		_pj(mod, b1, s1, s2)
		_pi(t, mod, b1, b2, s1)
	_ph()
	for name in CRITERIA:
		if not _reported.has(name):
			_fail += 1
			print("!!  %s: never reported, so nothing was measured" % name)
	remove_child(t)
	t.free()
	print("\n=== %s (%d failures) ===\n" % ["PATH PARAM PASS" if _fail == 0 else "PATH PARAM FAIL", _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _check(p_name: String, p_ok: bool, p_detail: String) -> void:
	_reported[p_name] = true
	if not p_ok:
		_fail += 1
	print("%s %s: %s" % ["   " if p_ok else "!! ", p_name, p_detail])


# ---- criteria ------------------------------------------------------------------------------------------

func _pa(g: Pasture3DTerrainGraph, mod: Pasture3DNodeGraph, b1: Node, b2: Node, s1: Pasture3DSpline,
		s2: Pasture3DSpline) -> void:
	print("[PA] each host evaluates its own spline")
	mod.stamp_params(b1)
	var h1 := _eval(g)
	var h1_ora := _eval_gd(g)
	mod.stamp_params(b2)
	var h2 := _eval(g)
	var h2_ora := _eval_gd(g)
	var t1 := _eval(_twin(s1.graph_spline_path()))
	var t2 := _eval(_twin(s2.graph_spline_path()))
	_check("PA", _worst(h1, t1) < 1.0e-6, "host 1 = Spline Source on spline 1: worst %.7f" % _worst(h1, t1))
	_check("PA", _worst(h2, t2) < 1.0e-6, "host 2 = Spline Source on spline 2: worst %.7f" % _worst(h2, t2))
	_check("PA", _sum(h1) > 10.0 and _sum(h2) > 10.0 and _worst(h1, h2) > 0.9,
			"the two hosts mask different lines: mass %.1f / %.1f, apart %.2f" % [_sum(h1), _sum(h2), _worst(h1, h2)])
	_check("PA", _worst(h1, h1_ora) < 1.0e-4 and _worst(h2, h2_ora) < 1.0e-4,
			"native = GDScript: %.7f / %.7f" % [_worst(h1, h1_ora), _worst(h2, h2_ora)])
	# CONTROL: no host, no spline.
	var lone := _host(g)
	lone.stamp_params(null)
	var h0 := _eval(g)
	_check("PA", _sum(h0) == 0.0, "control: stamped with no host, the mask is empty (mass %.1f)" % _sum(h0))


func _pb(g: Pasture3DTerrainGraph, mod: Pasture3DNodeGraph, b1: Node, b2: Node) -> void:
	print("[PB] a stamp emits nothing on the shared graph")
	_emits = 0
	g.changed.connect(_count)
	for i in 3:
		mod.stamp_params(b1)
		mod.stamp_params(b2)
	g.changed.disconnect(_count)
	_check("PB", _emits == 0, "six stamps alternating hosts emitted %d changed" % _emits)
	# CONTROL: the shared Spline Source the parameter replaces.
	var src := Pasture3DGraphNodeSplineSource.new()
	var sg := Pasture3DTerrainGraph.create_empty()
	sg.nodes = [src] as Array[Pasture3DGraphNode]
	_emits = 0
	sg.changed.connect(_count)
	for i in 3:
		Pasture3DGraphSources.resolve_splines(sg, b1)
		Pasture3DGraphSources.resolve_splines(sg, b2)
	sg.changed.disconnect(_count)
	_check("PB", _emits >= 6, "control: a shared empty-key Spline Source emitted %d changed over the same six" % _emits)


func _pc(g: Pasture3DTerrainGraph, mod: Pasture3DNodeGraph, b1: Node, b2: Node, s1: Pasture3DSpline) -> void:
	print("[PC] keys follow the host's spline, and an unchanged spline keeps its instance")
	var pn: Pasture3DGraphNodeParam = g.nodes[0]
	var k1 := mod.graph_key(b1)
	var inst1 := pn.resolved_path()
	var k2 := mod.graph_key(b2)
	var k1_again := mod.graph_key(b1)
	_check("PC", k1 != k2, "the two hosts key differently")
	_check("PC", k1 == k1_again and pn.resolved_path() == inst1 and inst1 != null,
			"re-stamping host 1 keeps its key and the same path instance")
	# CONTROL: without the memo an equal path is a new instance.
	mod._path_memo.clear()
	mod.stamp_params(b1)
	_check("PC", pn.resolved_path() != inst1 and pn.resolved_path().content_digest() == inst1.content_digest(),
			"control: with the memo dropped, the same spline stamps a new instance")
	# Move a point on spline 1.
	var c: Curve3D = (s1.get_child(0) as Path3D).curve
	var was := c.get_point_position(1)
	c.set_point_position(1, was + Vector3(0.0, 0.0, 15.0))
	var k1_moved := mod.graph_key(b1)
	var k2_after := mod.graph_key(b2)
	c.set_point_position(1, was)
	var k1_back := mod.graph_key(b1)
	_check("PC", k1_moved != k1 and k2_after == k2 and k1_back == k1,
			"moving spline 1 moves host 1's key only, and putting it back restores it")


func _pd(g: Pasture3DTerrainGraph, b1: Node, b3: Node, s2: Pasture3DSpline) -> void:
	print("[PD] a typed key overrides the host's own spline")
	var own := _host(g)
	own.set_param(&"spine", s2.spline_key())
	own.stamp_params(b1)
	var by_key := _eval(g)
	var t2 := _eval(_twin(s2.graph_spline_path()))
	_check("PD", _worst(by_key, t2) < 1.0e-6, "host 1 keyed to spline 2 masks spline 2: worst %.7f" % _worst(by_key, t2))
	_check("PD", not _warned(own, b1), "control: a key that resolves raises no spline-parameter warning")
	var bad := _host(g)
	bad.set_param(&"spine", "Terrain/Nowhere")
	_check("PD", _warned(bad, b1), "a key naming no spline is warned")
	var bare := _host(g)
	_check("PD", _warned(bare, b3), "an empty key on a brush with no spline child is warned")


func _pe(t: Node, b1: Pasture3DTerrainBrush, b2: Pasture3DTerrainBrush, s1: Pasture3DSpline,
		s2: Pasture3DSpline) -> void:
	print("[PE] a spline edit reaches the brushes reading it")
	var g3 := _graph()
	var keyed := _host(g3)
	keyed.set_param(&"spine", s2.spline_key())
	var b4 := _brush(t, "Keyed", Vector3(0.0, 0.0, -150.0), false)
	b4.modifiers = [keyed] as Array[Pasture3DNode]
	var plain := _brush(t, "Plain", Vector3(0.0, 0.0, -250.0), false)
	var pg := Pasture3DTerrainGraph.create_empty()
	pg.nodes = [Pasture3DGraphNodeInput.new(), Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	pg.connect_ports(0, 0, 1, 0)
	plain.modifiers = [_host(pg)] as Array[Pasture3DNode]
	var k1 := s1.spline_key()
	var k2 := s2.spline_key()
	_check("PE", s1._brush_reads_spline(b1, k1) and not s1._brush_reads_spline(b2, k1)
			and not s1._brush_reads_spline(b4, k1), "spline 1 is read by host 1 only")
	_check("PE", s2._brush_reads_spline(b2, k2) and s2._brush_reads_spline(b4, k2)
			and not s2._brush_reads_spline(b1, k2), "spline 2 is read by host 2 and by the brush naming it")
	_check("PE", not s1._brush_reads_spline(plain, k1) and not s2._brush_reads_spline(plain, k2),
			"control: a brush with no PATH parameter reads neither")


func _pf(mod: Pasture3DNodeGraph, b1: Node, s2: Pasture3DSpline) -> void:
	print("[PF] the host inspector")
	var copy: Pasture3DNodeGraph = mod.duplicate(false)
	copy.param_overrides = {}
	copy.stamp_params(b1)
	var info := {}
	for p in copy.get_property_list():
		if p["name"] == "parameters/spine":
			info = p
	_check("PF", not info.is_empty() and int(info["type"]) == TYPE_STRING
			and int(info.get("hint", 0)) == PROPERTY_HINT_ENUM_SUGGESTION
			and String(info.get("hint_string", "")).split(",").has(s2.spline_key()),
			"parameters/spine is a String offering the scene's keys: %s" % str(info))
	var group := false
	var readout := false
	for p in copy.get_property_list():
		if p["name"] == "Parameters" and int(p["usage"]) & PROPERTY_USAGE_GROUP and p["hint_string"] == "parameters/":
			group = true
		if p["name"] == "parameters/spine__reads" and int(p["usage"]) & PROPERTY_USAGE_READ_ONLY:
			readout = true
	var s1_key: String = Pasture3DGraphSources.own_spline(b1).spline_key()
	var reads_own := String(copy.get("parameters/spine__reads"))
	var read_default: Variant = copy.get("parameters/spine")
	copy.set("parameters/spine", s2.spline_key())
	var reads_keyed := String(copy.get("parameters/spine__reads"))
	_check("PF", group and readout, "a Parameters group, and a read-only readout under the spline parameter")
	_check("PF", reads_own.begins_with(s1_key) and reads_own.contains("own") and reads_keyed == s2.spline_key(),
			"the readout names the spline read: \"%s\", then \"%s\"" % [reads_own, reads_keyed])
	var read_set: Variant = copy.get("parameters/spine")
	var stored: Variant = copy.param_overrides.get(&"spine")
	copy.set("parameters/spine", "")
	_check("PF", read_default is String and String(read_default).is_empty() and read_set == s2.spline_key()
			and stored == s2.spline_key() and not copy.param_overrides.has(&"spine"),
			"reads \"\" by default, stores a typed key, and \"\" clears it")


func _pg(mod: Pasture3DNodeGraph, b1: Node, b2: Node) -> void:
	print("[PG] the content key follows the host stamped last")
	mod.stamp_params(b1)
	var c1 := mod.content_key()
	mod.stamp_params(b2)
	var c2 := mod.content_key()
	_check("PG", c1 != c2, "control: host 1 and host 2 key differently through content_key")
	mod.stamp_params(b1)
	_check("PG", mod.content_key() == c1 and mod.graph_key() == mod.graph_key(b1),
			"content_key and graph_key() read the host stamped last")


func _ph() -> void:
	print("[PH] retargeting an unwired Parameter redraws its port")
	var g := Pasture3DTerrainGraph.create_empty()
	var fa := Pasture3DGraphParam.new(); fa.id = &"a"
	var fb := Pasture3DGraphParam.new(); fb.id = &"b"
	g.parameters = [fa, fb, _decl()] as Array[Pasture3DGraphParam]
	var pn := Pasture3DGraphNodeParam.new()
	g.nodes = [pn, Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	pn.param_id = &"a"
	_emits = 0
	g.structure_changed.connect(_count)
	pn.param_id = &"b"
	var same := _emits
	pn.param_id = &"spine"
	var retyped := _emits - same
	g.structure_changed.disconnect(_count)
	_check("PH", pn.output_port_type() == Pasture3DGraphNode.PortType.PATH and retyped >= 1,
			"Float -> Path: port is PATH, structure_changed emitted %d time(s)" % retyped)
	_check("PH", same == 0, "control: Float -> Float emitted structure_changed %d time(s)" % same)


# ---- fixtures ------------------------------------------------------------------------------------------

func _pi(t: Node, mod: Pasture3DNodeGraph, b1: Pasture3DTerrainBrush, b2: Pasture3DTerrainBrush,
		s1: Pasture3DSpline) -> void:
	# What a duplicate of Hill1 looked like before: Hill2 holds Hill1's modifier, which names Hill1's spline.
	mod.param_overrides = {&"spine": s1.spline_key()}
	var got := Pasture3DBrushGraphRow.unshare_graph_mods(b2)
	var m2: Pasture3DNodeGraph = got[0] if got.size() == 1 else null
	var split_ok := m2 != null and m2 != mod and m2.graph == mod.graph and b2.modifiers.has(m2) and not b2.modifiers.has(mod) and m2.param_key(&"spine").is_empty()
	var kept := b1.modifiers.has(mod) and mod.param_key(&"spine") == s1.spline_key() and Pasture3DBrushGraphRow.unshare_graph_mods(b1) == [mod]
	# Control: a brush that does not host the graph. Its spline is named by key and must survive a split.
	var other := _brush(t, "Other", Vector3(0.0, 0.0, -150.0), true)
	var so := Pasture3DGraphSources.own_spline(other)
	mod.param_overrides = {&"spine": so.spline_key()}
	b2.modifiers = [mod] as Array[Pasture3DNode]
	var got2 := Pasture3DBrushGraphRow.unshare_graph_mods(b2)
	var survives: bool = got2.size() == 1 and got2[0] != mod and got2[0].param_key(&"spine") == so.spline_key()
	t.remove_child(other)
	other.free()
	b2.modifiers = [mod] as Array[Pasture3DNode]
	mod.param_overrides = {}
	_check("PI", split_ok and kept and survives, "split: own modifier, same graph, key cleared=%s | original kept with key=%s | non-host key survives (control)=%s"
			% [split_ok, kept, survives])


func _pj(mod: Pasture3DNodeGraph, b1: Node, s1: Pasture3DSpline, s2: Pasture3DSpline) -> void:
	mod.stamp_params(b1)
	mod.set_param(&"spine", s1.spline_key())
	var own_empty := not mod.param_overrides.has(&"spine")
	mod.set_param(&"spine", s2.spline_key())
	var other_kept := mod.param_key(&"spine") == s2.spline_key()
	mod.clear_param(&"spine")
	_check("PJ", own_empty and other_kept, "own spline stored as empty=%s | another's stored by key (control)=%s" % [own_empty, other_kept])


func _count() -> void:
	_emits += 1


## A Mound at `p_at` with a square outline, and when `p_with_spline` a Pasture3DSpline child carrying a
## straight north-south line through it.
func _brush(p_t: Node, p_name: String, p_at: Vector3, p_with_spline: bool) -> Pasture3DTerrainBrush:
	var m := Pasture3DMound.new()
	m.name = p_name
	p_t.add_child(m)
	m.position = p_at
	var outline := Path3D.new()
	outline.name = "Outline"
	var c := Curve3D.new()
	for p in [Vector3(-40, 0, -40), Vector3(40, 0, -40), Vector3(40, 0, 40), Vector3(-40, 0, 40)]:
		c.add_point(p)
	outline.curve = c
	m.add_child(outline)
	if p_with_spline:
		var sp := Pasture3DSpline.new()
		sp.name = "Spine"
		m.add_child(sp)
		sp.half_width = 6.0
		var line := Path3D.new()
		line.name = "Line"
		var lc := Curve3D.new()
		lc.add_point(Vector3(0.0, 0.0, -60.0))
		lc.add_point(Vector3(5.0, 0.0, 0.0))
		lc.add_point(Vector3(0.0, 0.0, 60.0))
		line.curve = lc
		sp.add_child(line)
	return m


func _decl() -> Pasture3DGraphParam:
	var d := Pasture3DGraphParam.new()
	d.id = &"spine"
	d.type = Pasture3DGraphParam.Type.PATH
	return d


## Parameter(spine, PATH) -> Path Mask -> Output.
func _graph() -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	g.parameters = [_decl()] as Array[Pasture3DGraphParam]
	var pn := Pasture3DGraphNodeParam.new()
	pn.param_id = &"spine"
	g.nodes = [pn, Pasture3DGraphNodeRegistry.create(&"path_mask"), Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	g.set_host_params({})
	_wire(g, 0, 1, 0)
	_wire(g, 1, 2, 0)
	return g


## The same graph with a Spline Source holding `p_path` where the parameter was.
func _twin(p_path: Pasture3DGraphPath) -> Pasture3DTerrainGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	var src := Pasture3DGraphNodeSplineSource.new()
	src.path = p_path
	g.nodes = [src, Pasture3DGraphNodeRegistry.create(&"path_mask"), Pasture3DGraphNodeOutput.new()] as Array[Pasture3DGraphNode]
	_wire(g, 0, 1, 0)
	_wire(g, 1, 2, 0)
	return g


func _wire(p_g: Pasture3DTerrainGraph, p_from: int, p_to: int, p_port: int) -> void:
	if not p_g.connect_ports(p_from, 0, p_to, p_port):
		_fail += 1
		print("!!  fixture wire %d -> %d:%d refused: %s" % [p_from, p_to, p_port, p_g.wire_problem(p_from, 0, p_to, p_port)])


func _host(p_g: Pasture3DTerrainGraph) -> Pasture3DNodeGraph:
	var m := Pasture3DNodeGraph.new()
	m.graph = p_g
	m.evaluation = Pasture3DNode.Evaluation.LIVE
	return m


func _warned(p_mod: Pasture3DNodeGraph, p_host: Node) -> bool:
	for w in p_mod.modifier_warnings(p_host):
		if w.contains("spline parameter"):
			return true
	return false


func _eval(p_g: Pasture3DTerrainGraph) -> PackedFloat32Array:
	var base := PackedFloat32Array()
	base.resize(N * N)
	return Pasture3DUtil.graph_eval_grid(p_g.compile_graph_program(), N, N, RECT, base)


func _eval_gd(p_g: Pasture3DTerrainGraph) -> PackedFloat32Array:
	var base := PackedFloat32Array()
	base.resize(N * N)
	p_g.force_gdscript_evaluation = true
	var out: PackedFloat32Array = p_g.evaluate(N, N, RECT, null, base)
	p_g.force_gdscript_evaluation = false
	return out


static func _sum(p_a: PackedFloat32Array) -> float:
	var s := 0.0
	for v in p_a:
		s += v
	return s


static func _worst(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> float:
	if p_a.size() != p_b.size() or p_a.is_empty():
		return INF
	var w := 0.0
	for i in p_a.size():
		w = maxf(w, absf(p_a[i] - p_b[i]))
	return w
