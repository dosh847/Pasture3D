# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# GraphColorSinkEditGate — editing a node that feeds a sink, and not the Output, reaches the terrain.
#
# `Pasture3DTerrainGraph._on_node_changed` decided "re-bake?" from the Output alone, so a Const Color wired
# into a Color Sink changed nothing on the terrain until something else baked. Now:
#   * a colour-only node feeding a sink emits `sinks_changed` (no revision bump) and the host re-runs its
#     sink pass over the surface it last baked -- no raster, no solve;
#   * any other node feeding only a sink emits `changed`, a normal re-bake.
#
#   [A] After a bake, editing the wired Const Color and running the host's re-run changes the terrain
#       colour. CONTROL: before the re-run the terrain still holds the old colour.
#   [B] The colour edit does not move `content_key()` (no cache keyed on it misses) and emits
#       `sinks_changed` once. CONTROL: an unwired Const Color edit emits neither.
#   [C] A mask edit feeding only the sink bumps the revision (a content change). CONTROL: before the fix
#       this edit emitted nothing; asserted as "revision moved".
#   [D] The brush heard the modifier: `_pending_sink_reruns` holds it after the edit, and the deferred
#       flush empties it.
extends Node

const N: int = 128
const HALF: float = 40.0
const PROBE := Vector3(64.0, 0.0, 64.0)

var _fail := 0
var _checks := 0


func _check(p_ok: bool, p_msg: String) -> void:
	_checks += 1
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_msg])


func _ready() -> void:
	print("=== GraphColorSinkEditGate ===")
	await _run()
	await _paint_only()
	if _checks < 19:
		print("!! GATE INCOMPLETE: %d checks" % _checks)
		_fail += 1
	print("=== GraphColorSinkEditGate: %s (%d failures, %d checks) ===" % ["PASS" if _fail == 0 else "FAIL", _fail, _checks])
	get_tree().quit(0 if _fail == 0 else 1)


func _terrain() -> Pasture3D:
	var t := Pasture3D.new()
	t.vertex_spacing = 1.0
	add_child(t)
	t.data.add_region_blankp(Vector3.ZERO)
	for iz in range(N):
		for ix in range(N):
			t.data.set_height(Vector3(float(ix) + 0.5, 0.0, float(iz) + 0.5), 10.0)
	return t


func _mound(p_t: Pasture3D) -> Pasture3DMound:
	var m := Pasture3DMound.new()
	add_child(m)
	m.terrain = p_t
	m.global_position = Vector3(64.0, 0.0, 64.0)
	m.height = 20.0
	var path := Path3D.new()
	var c := Curve3D.new()
	c.add_point(Vector3(-HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, -HALF))
	c.add_point(Vector3(HALF, 0.0, HALF))
	c.add_point(Vector3(-HALF, 0.0, HALF))
	c.closed = true
	path.curve = c
	m.add_child(path)
	return m


func _mask() -> Pasture3DGraphNodeMask:
	var k := Pasture3DGraphNodeMask.new()
	k.property = Pasture3DGraphNodeMask.Property.ALTITUDE
	k.band_min = -1000000.0
	k.band_max = 1000000.0
	k.falloff_lo = 0.0
	k.falloff_hi = 0.0
	return k


func _near(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.02 and absf(a.g - b.g) < 0.02 and absf(a.b - b.b) < 0.02


func _run() -> void:
	var t := _terrain()
	var m := _mound(t)
	var g := Pasture3DTerrainGraph.create_empty()
	var nodes: Array[Pasture3DGraphNode] = []
	nodes.append(Pasture3DGraphNodeInput.new())      # 0
	nodes.append(_mask())                            # 1 -> Output
	nodes.append(Pasture3DGraphNodeOutput.new())     # 2
	nodes.append(_mask())                            # 3 -> sink mask
	var col := Pasture3DGraphNodeConstColor.new()
	col.value = Color.RED
	nodes.append(col)                                # 4 -> sink colour
	var sink := Pasture3DGraphNodeColorSink.new()
	sink.resource_name = "S"
	nodes.append(sink)                               # 5
	var stray := Pasture3DGraphNodeConstColor.new()
	nodes.append(stray)                              # 6, unwired
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, 0, 2, 0], [0, 0, 3, 0], [3, 0, 5, 0], [4, 0, 5, 1]]
	g.output_node = 2
	var mod := Pasture3DNodeGraph.new()
	mod.graph = g
	m.modifiers = [mod] as Array[Pasture3DNode]

	m._stamp_cache.clear()
	m._refresh_owner(m._layer_owner, false, [])
	await get_tree().process_frame
	var c0: Color = t.data.get_color(PROBE)
	_check(_near(c0, Color.RED), "the bake painted the sink's red (%s)" % c0)

	var sinks_hits := [0]
	var changed_hits := [0]
	g.sinks_changed.connect(func(_i): sinks_hits[0] += 1)
	g.changed.connect(func(): changed_hits[0] += 1)

	print("  [B] an unwired colour edit emits nothing")
	var rev0 := g.content_key()
	stray.value = Color.YELLOW
	_check(sinks_hits[0] == 0 and changed_hits[0] == 0, "control: unwired colour emits neither (%d, %d)" % [sinks_hits[0], changed_hits[0]])

	print("  [A][B][D] the wired colour edit")
	col.value = Color.BLUE
	_check(sinks_hits[0] == 1, "sinks_changed emitted once (%d)" % sinks_hits[0])
	_check(changed_hits[0] == 0 and g.content_key() == rev0, "no changed, revision unmoved (%d -> %d)" % [rev0, g.content_key()])
	_check(m._pending_sink_reruns.has(mod.get_instance_id()), "the brush queued a sink re-run for the modifier")
	var stale: Color = t.data.get_color(PROBE)
	_check(_near(stale, Color.RED), "control: before the re-run the terrain is still red (%s)" % stale)
	await get_tree().process_frame
	_check(m._pending_sink_reruns.is_empty(), "the deferred flush ran")
	var c1: Color = t.data.get_color(PROBE)
	_check(_near(c1, Color.BLUE), "after the re-run the terrain is blue (%s)" % c1)
	_check(m._rerun_graph_sinks(mod), "a direct re-run reports it ran over the recorded surface")

	print("  [C] a mask feeding only the sink is a content change")
	var rev1 := g.content_key()
	(nodes[3] as Pasture3DGraphNodeMask).band_min = -999999.0
	_check(g.content_key() != rev1, "the revision moved (%d -> %d)" % [rev1, g.content_key()])
	_check(sinks_hits[0] == 1, "and it did not take the colour-only route (%d)" % sinks_hits[0])

	m.queue_free()
	t.queue_free()


## [E] A paint-only graph (Input -> Mask -> Color Sink, no Output) is active, paints, and leaves the height
## exactly as the brush alone makes it. CONTROLS: the same graph without its sink is inactive; the height
## is compared against a bake with the modifier disabled.
func _paint_only() -> void:
	print("  [E] a graph with sinks and no Output")
	var t := _terrain()
	var m := _mound(t)
	var g := Pasture3DTerrainGraph.create_empty()
	var nodes: Array[Pasture3DGraphNode] = []
	nodes.append(Pasture3DGraphNodeInput.new())      # 0
	nodes.append(_mask())                            # 1
	var col := Pasture3DGraphNodeConstColor.new()
	col.value = Color.GREEN
	nodes.append(col)                                # 2
	nodes.append(Pasture3DGraphNodeColorSink.new())  # 3
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, 0, 3, 0], [2, 0, 3, 1]]
	var mod := Pasture3DNodeGraph.new()
	mod.graph = g
	_check(g.output_index() < 0, "precondition: the graph has no Output")
	_check(mod.is_sinks_only() and mod.is_active(), "a sink with no Output is active")
	var bare := Pasture3DTerrainGraph.create_empty()
	var bnodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), _mask()]
	bare.nodes = bnodes
	bare.connections = [[0, 0, 1, 0]]
	var bare_mod := Pasture3DNodeGraph.new()
	bare_mod.graph = bare
	_check(not bare_mod.is_active(), "control: the same graph without its sink is inactive")

	mod.enabled = false
	m.modifiers = [mod] as Array[Pasture3DNode]
	m._stamp_cache.clear()
	m._refresh_owner(m._layer_owner, false, [])
	await get_tree().process_frame
	var h_ref: float = t.data.get_height(PROBE)
	var c_ref: Color = t.data.get_color(PROBE)
	_check(not _near(c_ref, Color.GREEN), "control: disabled, the terrain is not green (%s)" % c_ref)

	mod.enabled = true
	m._stamp_cache.clear()
	m._refresh_owner(m._layer_owner, false, [])
	await get_tree().process_frame
	var c: Color = t.data.get_color(PROBE)
	_check(_near(c, Color.GREEN), "the paint-only graph painted green (%s)" % c)
	var h: float = t.data.get_height(PROBE)
	_check(is_equal_approx(h, h_ref), "the height is the brush's own (%.4f vs %.4f)" % [h, h_ref])

	var hits := [0, 0]
	g.sinks_changed.connect(func(_i): hits[0] += 1)
	g.changed.connect(func(): hits[1] += 1)
	col.value = Color.MAGENTA
	_check(hits[0] == 1 and hits[1] == 0, "its colour edit takes the sink route (%d sinks, %d changed)" % hits)
	await get_tree().process_frame
	var c2: Color = t.data.get_color(PROBE)
	_check(_near(c2, Color.MAGENTA), "and repaints (%s)" % c2)
	m.queue_free()
	t.queue_free()
