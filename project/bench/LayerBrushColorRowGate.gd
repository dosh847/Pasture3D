# LayerBrushColorRowGate — the members of a Pasture3DLayerBrush share ONE colour row, and every member's
# Color Sink survives in it, composited in member order.
#
# WHY THIS EXISTS. Members bake under the Layer's owner, so their Color Sinks already named one row
# (`<layer owner>#graph_color`). But each sink's run cleared that row over its own rect (whole tiles) before
# writing, and the bake repaints every member in turn — so each member erased the ones painted before it and
# only the LAST member's colour was ever on the terrain. The bake's pre-clear has already dropped the row
# over every member's footprint, so the brush now hands its sinks a bake-wide cleared set
# (Pasture3DGraphChannelSinks.bake_cleared) and the second clear is skipped.
#
# Fixture: Layer "Group" with members A (x 16..40, red) and B (x 32..56, blue), overlapping on 32..40.
#   [A] one row: both members' sinks write under the Layer's owner, into a single colour layer.
#   [B] after Bake All: A-only cell red, overlap blue (B is later in member order), B-only cell blue.
#   [C] after re-baking A alone (its edit repaints the whole group): the same three colours.
#   [D] CONTROL: with the shared cleared set off, A's colour is wiped — so [B]/[C] can fail.
#
# FROZEN members (the demo's three PaintIslands: only one ever showed). A frozen graph's sinks run only when a
# Bake asks (`sinks_requested`); otherwise they keep the last Bake's paint, so the bake must not clear a row
# no writer will repaint. But the row is SHARED, and one member's Bake used to clear it over its rect and
# erase the others, who were not asked to repaint.
#   [E] A is Baked (cache dropped), synchronous route: B is repainted with it and keeps its colour.
#   [F] B moves (its spline is edited) with no Bake: no sink runs, every colour stays where it was baked,
#       nothing follows B to its new place, and B's graph reports stale.
#   [J] B's NODE moves with no Bake: the same.
#   [G] A is Baked on the deferred driver (the editor's route): B keeps its colour.
#   [H] Nothing changed: a frozen re-bake writes no cells at all and every colour stays.
#   [I] A drives the bake; B, a later SIBLING, was Baked. Counting only the baking brush's graphs kept the
#       row, A skipped, and B's sink then cleared it under A.
#   Controls: [I] fails with only the baking brush's graphs counted; [F]/[J] fail with B under the old
#   rule (`force_sinks_on_served`), where its paint follows the move. ([E]/[G] pass either way: B follows A,
#   so it already sees the row cleared when its turn comes.)
extends Node

var _fail := 0
var _checks := 0


func _check(p_ok: bool, p_msg: String) -> void:
	_checks += 1
	if not p_ok:
		_fail += 1
	print("    %s %s" % ["ok  " if p_ok else "FAIL", p_msg])


func _ready() -> void:
	print("=== LayerBrushColorRowGate ===")
	await _shared_row()
	await _control()
	await _frozen_cases()
	if _checks < 40:
		print("!! GATE INCOMPLETE: %d checks" % _checks)
		_fail += 1
	print("=== LayerBrushColorRowGate: %s (%d failures, %d checks) ===" % ["PASS" if _fail == 0 else "FAIL", _fail, _checks])
	get_tree().quit(0 if _fail == 0 else 1)


func _mask() -> Pasture3DGraphNodeMask:
	var k := Pasture3DGraphNodeMask.new()
	k.property = Pasture3DGraphNodeMask.Property.ALTITUDE
	k.band_min = -1000000.0
	k.band_max = 1000000.0
	k.falloff_lo = 0.0
	k.falloff_hi = 0.0
	return k


var _frozen := false


func _graph(p_col: Color) -> Pasture3DNodeGraph:
	var g := Pasture3DTerrainGraph.create_empty()
	var nodes: Array[Pasture3DGraphNode] = [Pasture3DGraphNodeInput.new(), _mask(), Pasture3DGraphNodeOutput.new(), _mask()]
	var c := Pasture3DGraphNodeConstColor.new()
	c.value = p_col
	nodes.append(c)
	nodes.append(Pasture3DGraphNodeColorSink.new())
	g.nodes = nodes
	g.connections = [[0, 0, 1, 0], [1, 0, 2, 0], [0, 0, 3, 0], [3, 0, 5, 0], [4, 0, 5, 1]]
	g.output_node = 2
	var mod := Pasture3DNodeGraph.new()
	mod.graph = g
	mod.evaluation = Pasture3DNode.Evaluation.FROZEN if _frozen else Pasture3DNode.Evaluation.LIVE
	return mod


func _mound(p_t: Pasture3D, p_parent: Node, p_name: String, x0: float, p_col: Color) -> Pasture3DMound:
	var m := Pasture3DMound.new()
	m.name = p_name
	m.terrain = p_t
	m.auto_refresh = false
	m.force_deferred_erosion = true
	var path := Path3D.new()
	var c := Curve3D.new()
	for p in [Vector3(x0, 0, 16), Vector3(x0 + 24, 0, 16), Vector3(x0 + 24, 0, 48), Vector3(x0, 0, 48)]:
		c.add_point(p)
	c.closed = true
	path.curve = c
	m.add_child(path)
	var ms: Array[Pasture3DNode] = [_graph(p_col)]
	m.modifiers = ms
	p_parent.add_child(m)
	return m


## A fresh terrain with the two-member Layer. Returns [terrain, layer, a, b].
func _scene() -> Array:
	var t := Pasture3D.new()
	t.vertex_spacing = 1.0
	add_child(t)
	t.data.add_region_blank(Vector2i(0, 0), true)
	t.data.ensure_layer_stack()
	var lb := Pasture3DLayerBrush.new()
	lb.name = "Group"
	lb.terrain = t
	lb.auto_refresh = false
	lb.force_deferred_erosion = true
	t.add_child(lb)
	var a := _mound(t, lb, "A", 16, Color.RED)
	var b := _mound(t, lb, "B", 32, Color.BLUE)
	await get_tree().process_frame
	return [t, lb, a, b]


func _col(p_t: Pasture3D, p_x: float) -> Color:
	return p_t.data.get_color(Vector3(p_x + 0.5, 0, 32.5))


func _near(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.02 and absf(a.g - b.g) < 0.02 and absf(a.b - b.b) < 0.02


func _colours(p_t: Pasture3D, p_tag: String) -> void:
	var c20 := _col(p_t, 20)
	var c36 := _col(p_t, 36)
	var c52 := _col(p_t, 52)
	_check(_near(c20, Color.RED), "%s: A-only cell (x=20) is A's red, got %s" % [p_tag, c20])
	_check(_near(c36, Color.BLUE), "%s: overlap (x=36) is B's blue, the later member, got %s" % [p_tag, c36])
	_check(_near(c52, Color.BLUE), "%s: B-only cell (x=52) is B's blue, got %s" % [p_tag, c52])


func _shared_row() -> void:
	print("[A]-[C] members share one colour row and both survive")
	var s := await _scene()
	var t: Pasture3D = s[0]
	var a: Pasture3DMound = s[2]
	var b: Pasture3DMound = s[3]
	await s[1].bake_layer_run()
	var row := a._layer_owner + Pasture3DGraphNodeColorSink.new().sink_owner_suffix()
	var rows := 0
	var st = t.data.get_layer_stack()
	for i in st.get_layer_count():
		var l = st.get_layer(i)
		if String(l.get_owner_id()).begins_with(a._layer_owner) and l.get_map_type() == 2:
			rows += 1
	_check(a.graph_sink_owner_base() == a._layer_owner and b.graph_sink_owner_base() == a._layer_owner and a._layer_owner != "",
			"both members' sinks write under the Layer's owner (%s)" % a._layer_owner)
	_check(rows == 1, "the Layer owns exactly one colour row (%s), found %d" % [row, rows])
	_colours(t, "[B] Bake All")
	a.height = 12.0
	a._stamp_cache.clear()
	a._refresh_owner(a._layer_owner, false, [])
	await get_tree().process_frame
	_colours(t, "[C] re-bake A")
	t.queue_free()
	await get_tree().process_frame


func _control() -> void:
	print("[D] CONTROL: without the bake-wide cleared set, a later member wipes an earlier one")
	Pasture3DTerrainBrush.sink_clear_scope_enabled = false
	var s := await _scene()
	var t: Pasture3D = s[0]
	await s[1].bake_layer_run()
	var c20 := _col(t, 20)
	Pasture3DTerrainBrush.sink_clear_scope_enabled = true
	_check(not _near(c20, Color.RED), "control: A's red is gone at x=20 with the scope off (got %s)" % c20)
	t.queue_free()
	await get_tree().process_frame


func _frozen_scene() -> Array:
	_frozen = true
	var s := await _scene()
	_frozen = false
	# Bake All Brushes: the request a frozen graph's sinks wait for.
	s[1].bake_all_brushes_now()
	await get_tree().process_frame
	return s


func _resolve_a(s: Array) -> void:
	var a: Pasture3DMound = s[2]
	a.modifiers[0].clear_cache()
	a._stamp_cache.clear()
	a._refresh_owner(a._layer_owner, false, [])
	await get_tree().process_frame


## B is Baked but the bake is driven from A (a group bake reaching B through A's repaint).
func _resolve_b(s: Array) -> void:
	var a: Pasture3DMound = s[2]
	var b: Pasture3DMound = s[3]
	b.modifiers[0].clear_cache()
	b._stamp_cache.clear()
	a._stamp_cache.clear()
	a._refresh_owner(a._layer_owner, false, [])
	await get_tree().process_frame


func _move_b(s: Array) -> void:
	var b: Pasture3DMound = s[3]
	var c: Curve3D = b.get_child(0).curve
	for i in c.point_count:
		c.set_point_position(i, c.get_point_position(i) + Vector3(0, 0, 6))
	b._stamp_cache.clear()
	b._refresh_owner(b._layer_owner, false, [])
	await get_tree().process_frame


func _move_b_node(s: Array) -> void:
	var b: Pasture3DMound = s[3]
	b.position.z += 6.0
	b._stamp_cache.clear()
	b._refresh_owner(b._layer_owner, false, [])
	await get_tree().process_frame


func _deferred_a(s: Array) -> void:
	var a: Pasture3DMound = s[2]
	a.modifiers[0].clear_cache()
	a._stamp_cache.clear()
	await a._bake_deferred(a._refresh_owner.bind(a._layer_owner, false, []), a._layer_owner, false)
	await get_tree().process_frame


func _frozen_case(p_tag: String, p_edit: Callable) -> void:
	var s := await _frozen_scene()
	var t: Pasture3D = s[0]
	_check(_near(_col(t, 20), Color.RED) and _near(_col(t, 52), Color.BLUE), "%s: frozen Bake All painted both members" % p_tag)
	await p_edit.call(s)
	_colours(t, p_tag)
	t.queue_free()
	await get_tree().process_frame


## True when the edit leaves A's red or B's blue missing, i.e. the control bit.
func _frozen_breaks(p_edit: Callable) -> bool:
	var s := await _frozen_scene()
	var t: Pasture3D = s[0]
	await p_edit.call(s)
	var broke := not (_near(_col(t, 20), Color.RED) and _near(_col(t, 36), Color.BLUE) and _near(_col(t, 52), Color.BLUE))
	t.queue_free()
	await get_tree().process_frame
	return broke


## A frozen B moved with no Bake: returns [cells written, colour at a cell only the NEW footprint covers,
## B stale]. `p_old_rule` runs B under `force_sinks_on_served`, the control.
func _move_without_bake(p_tag: String, p_edit: Callable, p_old_rule: bool) -> Array:
	var s := await _frozen_scene()
	var t: Pasture3D = s[0]
	var b: Pasture3DMound = s[3]
	b.force_sinks_on_served = p_old_rule
	var w0 := Pasture3DGraphChannelSinks.write_count
	await p_edit.call(s)
	# z 50.5 lies in B's moved footprint (z 22..54) and outside the one it was baked over (z 16..48).
	var fresh := t.data.get_color(Vector3(52.5, 0, 50.5))
	var out := [Pasture3DGraphChannelSinks.write_count - w0, fresh, bool(b.modifiers[0]._stale)]
	if not p_old_rule:
		_check(int(out[0]) == 0, "%s: no sink ran (%d cells written)" % [p_tag, int(out[0])])
		_check(not _near(fresh, Color.BLUE), "%s: B's colour did not follow it to its new place (%s)" % [p_tag, fresh])
		_check(bool(out[2]), "%s: B's graph reports stale, so its warning asks for a Bake" % p_tag)
		_colours(t, p_tag)
	t.queue_free()
	await get_tree().process_frame
	return out


func _frozen_cases() -> void:
	print("[E]-[J] frozen members: only a Bake repaints, and a Bake does not erase the others")
	await _frozen_case("[E] A Baked", _resolve_a)
	await _frozen_case("[G] A Baked, deferred", _deferred_a)
	await _frozen_case("[I] sibling B Baked in A's bake", _resolve_b)
	await _move_without_bake("[F] B's spline moved", _move_b, false)
	await _move_without_bake("[J] B's node moved", _move_b_node, false)

	var s := await _frozen_scene()
	var t: Pasture3D = s[0]
	var a: Pasture3DMound = s[2]
	var w0 := Pasture3DGraphChannelSinks.write_count
	a._stamp_cache.clear()
	a._refresh_owner(a._layer_owner, false, [])
	await get_tree().process_frame
	_check(Pasture3DGraphChannelSinks.write_count == w0,
			"[H] unchanged frozen re-bake ran no sinks (%d cells written)" % (Pasture3DGraphChannelSinks.write_count - w0))
	_colours(t, "[H] unchanged re-bake")
	t.queue_free()
	await get_tree().process_frame

	Pasture3DTerrainBrush.shared_row_writers_enabled = false
	var i_none := await _frozen_breaks(_resolve_b)
	Pasture3DTerrainBrush.shared_row_writers_enabled = true
	_check(i_none, "control: counting only the baking brush's graphs, B's Bake erases A")
	var f_old := await _move_without_bake("[F] control", _move_b, true)
	var j_old := await _move_without_bake("[J] control", _move_b_node, true)
	_check(int(f_old[0]) > 0 and _near(f_old[1], Color.BLUE),
			"control: under the old rule B's spline move repaints and its colour follows (%d cells, %s)" % [int(f_old[0]), f_old[1]])
	_check(int(j_old[0]) > 0 and _near(j_old[1], Color.BLUE),
			"control: under the old rule B's node move repaints and its colour follows (%d cells, %s)" % [int(j_old[0]), j_old[1]])
